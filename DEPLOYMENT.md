# ai-notification-system — Local Deployment (Floci)

End-to-end runbook for standing up the whole platform on **one macOS host** using
Floci (a local Docker-based AWS emulator) instead of a real AWS account. Covers
what was built, the exact command sequence, verification, day-2 operations, and
the load-test phase.

> Target host: Apple Silicon Mac, **8 GB RAM / 8 cores** (the binding constraint —
> see §7). Everything runs serially; "delay is acceptable, contention is not".

---

## 1. Architecture

### 1.1 Three repos

| Repo | Role |
|---|---|
| `ai-notification-system` | Application code — 13 services under `apps/*` (12 NestJS + 1 Python/FastAPI), shared `packages/*`, the app Dockerfiles under `docker/`, and `loadtest/`. |
| `platform-gitops` | Deploy config — Helm charts (`k8s/charts/{nest-service,web,prediction-service}`), per-env values (`k8s/environments/{local,prod}`), ArgoCD `Application`/`ApplicationSet` manifests, and the CI **`jenkins/Jenkinsfile`**. ArgoCD watches this repo's `main`. |
| `platform-infrastructure` | This repo — Terraform (`main.tf` + `modules/*`) that brings up Floci, the two EKS-emulated k3s clusters, ArgoCD, observability, Jenkins, and ECR; plus `scripts/*` helpers. |

### 1.2 Container topology (all on the `floci-static` Docker network, `172.30.0.0/24`)

| Container | Pinned IP | Host port | What it is |
|---|---|---|---|
| `floci` | .2\* | 4566, 8000, 8080, 8091-8095 | The AWS emulator (ECR/EKS/VPC/ELBv2). Also runs the ALB emulation. |
| `floci-ecr-registry` | **.20** | **5100** → :5000 | `registry:2`. The "ECR". Plain HTTP. **No restart policy** (Floci-managed). |
| `floci-eks-ai-notification-floci` | **.10** | `localhost:6501` | k3s node = the **app_services** cluster (the 13 app workloads). |
| `floci-eks-floci-backing-services` | **.14** | `localhost:6500` | k3s node = the **backing_services** cluster (Postgres / RabbitMQ / Redis). |
| `floci-jenkins` | .21 | **9091** | Custom image: `jenkins/jenkins:lts` + pinned plugins + static `docker` CLI + `buildx`. Runs as root, mounts `/var/run/docker.sock` + a `/scratch` host dir. |
| `floci-argocd-{redis,repo-server,application-controller,applicationset-controller,server}` | .22-.26 | server → **9092** | ArgoCD as 5 plain containers (not a k8s install). Their KUBECONFIG targets app_services remotely. |
| `floci-otel-collector` | **.13** | — | OTLP → Jaeger (traces) + Prometheus exporter :8889 (metrics). |
| `floci-jaeger` | .27 | **9095** | Traces UI. `badger` persistence. |
| `floci-prometheus` | .28 | **9094** | Metrics. `--web.enable-lifecycle` (POST `/-/reload`). |
| `floci-grafana` | .29 | **9093** | Dashboards. |

\* `floci` itself is not IP-pinned; nothing references it by IP. Reserved band `.10-.20` = k3s nodes + otel + registry; plain containers are pinned `.21-.29` so a recreate can never collide with a k3s node's `.10`.

### 1.3 The GitOps flow

```
 dev pushes to ai-notification-system/main
        │
        ▼  (Jenkins job: build-<service>, or build-service SERVICES=all)
 docker build (BuildKit)  →  push to BOTH:
        ├─ localhost:5100/ai-notification/<svc>:<sha>        (Floci ECR — what k8s pulls)
        └─ docker.io/dip75016860/ai-notification:<svc>-<sha> (Docker Hub — durable off-box copy)
        │
        ▼  Jenkins sed-bumps k8s/environments/local/values-<svc>.yaml (image.repository/tag)
           and git-pushes that commit to platform-gitops/main
        │
        ▼  ArgoCD (auto-sync, selfHeal) sees the changed values file
 kubectl apply of the rendered chart onto the app_services cluster (namespace ai-notification)
        │
        ▼
 pods pull 172.30.0.20:5000/ai-notification/<svc>:<sha> via the k3s containerd registry mirror
```

Backing services (Postgres/RabbitMQ/Redis) are **not** GitOps — Terraform applies them
directly onto the backing_services cluster. app_services reaches them via stub
`Service`+`Endpoints` objects pointing at `172.30.0.14:<nodePort>` (same pattern as the
otel cross-cluster link).

---

## 2. Host prerequisites (one-time)

### 2.1 Docker Desktop settings

- **Memory: 5.5 GB** (`~/Library/Group Containers/group.com.docker/settings-store.json` → `"MemoryMiB": 5632`, then `docker desktop restart`). 8 GB is the whole machine — do **not** exceed ~5.5.
- **Settings → Advanced → "Allow the default Docker socket"** = ON (creates `/var/run/docker.sock`; Floci + Jenkins mount it).
- **Settings → Docker Engine** → add `"insecure-registries": ["172.30.0.20:5000"]` (the Floci ECR is plain HTTP). Or `~/.docker/daemon.json`.

### 2.2 CLI tools (no Homebrew on this host)

| Tool | Version | Location | Install |
|---|---|---|---|
| `terraform` | 1.16.0 | `~/bin/terraform` | download `releases.hashicorp.com`, verify SHA256, `install -m755` |
| `helm` | 3.16.3 | `~/bin/helm` | download `get.helm.sh`, verify SHA256 |
| `k6` | 0.54.0 | `~/bin/k6` | download GitHub release, verify checksum |
| `docker`, `kubectl`, `buildx` | Docker Desktop | `~/.docker/bin/` | bundled with Docker Desktop |

`~/.zshrc` puts them on PATH:
```sh
export PATH="$HOME/bin:$HOME/.docker/bin:$PATH"
```

### 2.3 Credentials → `platform-infrastructure/secrets.local.tfvars` (gitignored)

Copy `secrets.tfvars.example` → `secrets.local.tfvars`, `chmod 600`, fill:

```hcl
github_push_username = "dip7501686040"
github_push_token    = "<fine-grained PAT, repo-write on platform-gitops>"
dockerhub_username   = "dip75016860"
dockerhub_token      = "<Docker Hub access token, Read/Write>"
openai_api_key       = ""   # only needed for the async/AI pipeline + KEDA demo
# jwt_secret / postgres_password / rabbitmq_password: any non-empty dummy for local
```

`scripts/tf.sh` always injects `-var-file=envs/local.tfvars -var-file=secrets.local.tfvars`
and forces `-parallelism=1`. **Always drive Terraform through `scripts/tf.sh`, never bare `terraform`.**

Docker Hub note: free tier = 1 private repo, so the 13 images share **one public repo**
(`dip75016860/ai-notification`) with the service in the tag. New repos there default to public.

---

## 3. Deployment sequence

All paths relative to `~/platform-infrastructure` unless stated. Prefix every command with
`export PATH="$HOME/bin:$HOME/.docker/bin:$PATH"`.

### 3.1 Init

```bash
scripts/tf.sh init -backend-config=envs/local.backend.hcl -input=false
scripts/tf.sh validate
```

### 3.2 Scoped bring-up — Floci + ECR + Jenkins only

```bash
scripts/tf.sh apply -auto-approve \
  -target=module.floci \
  -target=module.ecr \
  -target=terraform_data.ensure_static_network \
  -target=terraform_data.ensure_ecr_registry_network \
  -target=docker_container.jenkins
```

Creates: the `floci` container (pulls `floci/floci:latest`), 13 ECR repos, the
`floci-static` network, `floci-ecr-registry` attached at `.20`, and `floci-jenkins`
(builds the custom image first — `templates/jenkins/Dockerfile`).

Verify:
```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep floci
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5100/v2/        # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9091/login      # 200 (Jenkins)
cat envs/state/jenkins-admin-password.txt
```

Jenkins seeds `build-<service>` jobs (×13) + `build-service` + `watch-source-and-build`
from `platform-gitops/main` at boot (`templates/jenkins/seed-jobs.groovy.tftpl`).

### 3.3 Build the 13 images

From the Jenkins UI (`http://localhost:9091`, `admin` / password above), run
`build-service` with `SERVICES=all, ENVIRONMENT=local`, or the individual
`build-<service>` jobs. Each job:

1. `git clone` ai-notification-system (public, anon).
2. `docker build` (BuildKit; `DOCKER_BUILDKIT=1`; `--provenance=false --sbom=false` so
   the plain `registry:2` accepts the image) with two `-t`:
   `localhost:5100/ai-notification/<svc>:<sha>` and
   `docker.io/dip75016860/ai-notification:<svc>-<sha>`.
3. `docker push` both. (Per-build `DOCKER_CONFIG` under `$WORKSPACE/.docker-cfg` so
   concurrent jobs don't clobber each other's `docker login`.)
4. `sed`-bump `k8s/environments/local/values-<svc>.yaml` and git-push to
   `platform-gitops/main`. (A no-op bump — same sha — is tolerated, not a failure.)

The `values-*.yaml` records `172.30.0.20:5000/ai-notification/<svc>` as the image repo
(the in-cluster pull address); the push itself goes via `localhost:5100` because Docker
Desktop can't route to custom-bridge container IPs from the host.

### 3.4 Full stack — the 2 clusters + ArgoCD + observability

```bash
scripts/tf.sh apply -auto-approve
```

~101 resources, serial (`parallelism=1`), ~15 min. Order (see `main.tf` "serial cluster
chain"): observability images/containers → argocd redis/repo-server → Floci VPC/subnets
for both clusters → k3s nodes → `ensure_restart_policies` (pins node IPs + k3s config) →
`ensure_registry_pull_mirror` (containerd HTTP mirror for `172.30.0.20:5000`) →
`k8s_reconcile` → app-secrets → Postgres → RabbitMQ → Redis → nodeports →
cross-cluster stubs → metrics-server (helm) → **KEDA** (helm) → remote-access token →
argocd containers → `argocd_bootstrap_configmaps` → `argocd_register_app_services`
(registers app_services as ArgoCD cluster `app-services`) → `argocd_manifests`
(CRDs + `default` AppProject + `web`/`prediction-service` Applications +
`nest-services-local` ApplicationSet).

Outputs: `web_url`, `api_gateway_url`, `argocd_url`, `grafana_url`, `prometheus_url`,
`jaeger_url`, `jenkins_url`, and `*_admin_password_path`.

### 3.5 Verify

```bash
export KUBECONFIG=~/platform-infrastructure/envs/state/kubeconfig-ai-notification-floci

# all 13 apps should be Synced + Healthy
kubectl get applications -n argocd -o custom-columns='N:.metadata.name,SYNC:.status.sync.status,H:.status.health.status'

# pods Running in the app namespace
kubectl get pods -n ai-notification

# cross-cluster networking (app_services -> backing_services)
kubectl get svc,endpoints -n ai-notification postgres rabbitmq redis
#   endpoints should be 172.30.0.14:<nodePort>
kubectl logs -n ai-notification deploy/api-gateway --tail=30 | grep -i 'RabbitMQ connected'
#   + every *-migrate PreSync job should be Completed (proves Postgres reachability)

# public URLs
for u in web:8080/login api-gateway:8000/health argocd:9092/healthz \
         grafana:9093/api/health prometheus:9094/-/healthy jaeger:9095/ ; do
  n=${u%%:*}; p=${u#*:}
  printf '%-12s %s\n' "$n" "$(curl -s -o /dev/null -m5 -w '%{http_code}' http://localhost:$p)"
done
```

---

## 4. Known gotchas seen during bring-up (and their fixes)

| Symptom | Cause | Fix |
|---|---|---|
| `exit status 127` in `keda_install` / any helm step | `helm` not installed | install helm → `~/bin/helm` (§2.2), re-run `scripts/tf.sh apply` |
| k3s node "invalid IP" on floci-static; `ensure_restart_policies` fails `Address already in use` | an argocd/observability container auto-grabbed `172.30.0.10` (they had no pinned IP originally) | fixed in `main.tf` — all plain containers now pinned `.21-.29`. If it recurs: `docker network disconnect -f floci-static <holder>; docker network connect --ip 172.30.0.10 floci-static floci-eks-ai-notification-floci; docker restart` it |
| ArgoCD app-controller logs `Unauthorized`, apps not syncing | argocd containers hold a stale target-kubeconfig after the k3s node was wiped/re-IP'd | `docker restart floci-argocd-{repo-server,application-controller,applicationset-controller,server}` |
| `Conflict. The container name "/floci-jenkins" is already in use` | kreuzwerker/docker provider destroy-then-create race on a `-target` replace | `docker rm -f <name>` then re-apply that target |
| `floci-ecr-registry` not running after a Docker restart | Floci gives it no restart policy | `docker start floci-ecr-registry` (or `scripts/safe-restart.sh`) |
| Jenkins boots with 0 plugins, `seed-jobs.groovy` fails on `import hudson.plugins.git.*` | stock `jenkins/jenkins:lts` does **not** install from a runtime `plugins.txt` | plugins are baked into the image at build time (`templates/jenkins/Dockerfile` + `plugins.txt`) |

---

## 5. Day-2 operations

### 5.1 After a Docker Desktop stop/restart, or `docker stop` of the k3s nodes

```bash
~/platform-infrastructure/scripts/safe-restart.sh
```

**Why it exists:** a Docker restart orphans all 13 app pods at once; letting kubelet
cold-start them together spiked this 8 GB host to load 44. The script is *minimal-touch*:

- starts only containers that are **stopped** (running ones untouched);
- re-pins the app node to `172.30.0.10` only if it drifted;
- deletes orphaned `Unknown`/`Error`/`CrashLoop`/`Completed` pods + finished Jobs
  (never a `Running` pod);
- finds `ai-notification` Deployments that are **not** fully ready, scales just those to
  0, then brings them back **`BATCH_SIZE=3` at a time, `BATCH_SLEEP=50s` apart**;
- restarts ArgoCD controllers only if not running / logging a burst of errors;
- leaves Jenkins as-is (`STOP_JENKINS=1` to force it down).

Env: `BATCH_SIZE`, `BATCH_SLEEP`, `WITH_OBSERVABILITY=1`, `STOP_JENKINS=0`, `FORCE_ALL=0`.

### 5.2 CPU discipline (mandatory on the 8 GB host)

Before anything heavy (a Terraform apply, a load test), give the app cluster priority
and make everything else wait — time is not the constraint, contention is:

```bash
docker update --cpus=5   floci-eks-ai-notification-floci
docker update --cpus=2   floci-eks-floci-backing-services
docker update --cpus=0.5 floci floci-prometheus floci-grafana floci-jaeger floci-otel-collector
docker update --cpus=0.3 floci-ecr-registry
```

`scripts/cpu-priority.sh` (sourced by every Terraform provisioner via `kubeconfig.sh`)
and the long-running `scripts/cpu-watchdog.sh` automate this.

### 5.3 Credentials / passwords

```
envs/state/jenkins-admin-password.txt      admin login for :9091
envs/state/argocd-admin-password.txt       admin login for :9092
envs/state/grafana-admin-password.txt      admin login for :9093
envs/state/kubeconfig-ai-notification-floci   KUBECONFIG for app_services
envs/state/kubeconfig-floci-backing-services  KUBECONFIG for backing_services
```

### 5.4 Rebuild one service after a code change

Push to `ai-notification-system/main` → run `build-<service>` in Jenkins → it pushes new
images + bumps the values file → ArgoCD syncs. Or trigger manually:
`kubectl -n argocd annotate application <svc> argocd.argoproj.io/refresh=hard --overwrite`
if you want an immediate re-check.

### 5.5 Tear down

```bash
scripts/tf.sh destroy -auto-approve       # removes all Terraform-managed containers/volumes
docker rm -f floci-ecr-registry           # Floci-managed, not in state
docker network rm floci-static
```

---

## 6. Load testing (Phase F)

Artifacts live in `ai-notification-system/loadtest/`:

| File | Purpose |
|---|---|
| `lib/setup.js` | shared `provisionTenant()` — register → tenant → **enabled rule** (mandatory; `POST /events` 400s without a matching rule). Fatal on failure. |
| `smoke.sh` | curl the flow once by hand. **Run before every k6 run.** |
| `mainflow-open.js` | `ramping-arrival-rate` 3→20 req/s — **finds the edge** (open model, exposes the knee). |
| `mainflow-closed.js` | `ramping-vus` 5→40 — realistic concurrent-user latency. |
| `hold.js` | `constant-arrival-rate` at a fixed rate — **sit in the broken state** for diagnosis / screenshots. |
| `diag.sh` | one-shot snapshot: host load, `kubectl top`, throttle queries, sync-path logs, Postgres `pg_stat_activity`, RabbitMQ depths. |
| `grafana-phaseF.json` | dashboard — `/events` rate/latency/504s, **pod CPU vs the 250m limit**, throttle ratio, mem vs 256Mi, RabbitMQ, + a Jaeger recipe panel. Import at `http://localhost:9093/dashboard/import`. |
| `hpa/api-gateway.yaml` | CPU HPA on the one clean candidate (no DB). |
| `hpa/db-owning-services.yaml` | HPA on `event-service` + `rule-engine-service` — applied deliberately to **document** the Postgres 100-connection ceiling, not to scale safely. |
| `keda/channel-service.yaml` | KEDA `ScaledObject` — scale the queue worker on RabbitMQ backlog. |

### 6.1 Method (repeatable for any flow)

1. **Model** the load (open vs closed), set an **SLO** (ours: `p95 < 300 ms`, errors `< 1 %`).
2. **Baseline**: `kubectl scale deploy --all -n ai-notification --replicas=1`, then
   `caffeinate -i k6 run --summary-export=loadtest/out/baseline-open.json loadtest/mainflow-open.js`.
   The knee = the ramp step where p95 crosses the SLO and errors climb.
3. **Diagnose** with the observability triangle while `hold.js` keeps it broken:
   `kubectl top` (which pod is at its limit) → Grafana (trends) → Jaeger (which span
   owns the latency) → `psql` / `rabbitmqctl` (rule out DB / broker).
4. **Fix**: `kubectl apply -f loadtest/hpa/…` (verify `kubectl get hpa` shows a real
   `TARGETS` %), re-run the **exact same** k6 command → `--summary-export=…hpa-open.json`.
5. **Compare** the two JSONs; then find the **new** edge (the bottleneck always moves).

### 6.2 Measured baseline (1 replica, `250m` CPU limit, sync path only)

`POST /events` sustains **~2–4 req/s** within SLO. Past that: p95 → 8 s, ~29 % `504`.
`event-service` sits at **234m / 250m**, `api-gateway` at **203m / 250m** — CPU-bound.
Postgres (18/100 conns) and RabbitMQ are not constrained. Jaeger shows the request time
is `dns.lookup` + `tcp.connect` on each downstream gRPC call (no channel pooling), on top
of the CPU throttle.

### 6.3 Planned, not yet applied

- **`ignoreDifferences` for `/spec/replicas`** on the ApplicationSet + `web`/`prediction`
  Applications in `platform-gitops` — required so ArgoCD `selfHeal` doesn't revert an
  HPA. Until then, `docker stop floci-argocd-application-controller` during HPA runs.
- **HPA on `api-gateway`** (max 3) + KEDA on `channel-service` — apply, re-run, prove.
- **Capacity projection** — extrapolate per-replica throughput to what real infra needs
  for the SRS targets (232 req/s avg, 2315 peak): replica count → vCPU/RAM → node count
  → + PgBouncer + a Redis cache on `identity.ValidateToken`.

### 6.4 Prometheus addition for the load test

The Floci Prometheus does **not** scrape cAdvisor by default. A `kubelet-cadvisor` job
was added to `envs/state/prometheus-config.yaml` (RBAC `ServiceAccount floci-prom-scraper`
+ token in `kube-system`) to get `container_cpu_usage_seconds_total`,
`container_cpu_cfs_throttled_periods_total`, `container_spec_cpu_quota`, etc. It is
bind-mounted (survives container restart) but **not in `main.tf`** — a `scripts/tf.sh apply`
reverts it (backup at `prometheus-config.yaml.bak`). To persist, fold the job into
`local_file.prometheus_config` in `main.tf`.

---

## 7. Known limitations & follow-ons

| Limitation | Impact | Real-infra answer |
|---|---|---|
| **8 GB / 8-core host** | Can't run all 13 pods + 2 k3s control planes + backing + observability under load; `maxReplicas × ~200 MiB` is the RAM ceiling | node autoscaling (Karpenter / cluster-autoscaler) |
| **Postgres `max_connections=100`, no pooler** | Prisma default pool × replicas × 9 DB-owning services hits `FATAL: too many clients` before CPU does | PgBouncer, or `?connection_limit=` in `DATABASE_URL` |
| **No gRPC channel pooling / DNS cache** | Every downstream RPC = new TCP connect + DNS lookup (100–500 ms) even though the RPC itself is <20 ms | reuse gRPC channels; cache `identity.ValidateToken` (Redis, short TTL) |
| **Async handlers `nack(false,false)`** | Under sustained overload, messages are dropped — no requeue, no DLX | RabbitMQ DLX + alerting |
| **No edge rate limiting** (`@nestjs/throttler` absent) | No load-shedding; the gateway degrades instead of rejecting | throttler / API-gateway rate limits |
| **ArgoCD `selfHeal` + no `ignoreDifferences`** | Fights an HPA over `/spec/replicas` | add `ignoreDifferences` (§6.3) |
| **Floci ECR = plain HTTP, no auth** | fine locally; **not** how prod ECR (HTTPS + IAM) should be pushed to | `envs/prod.tfvars` path — not yet built |
| **`prod` environment** | `k8s/environments/prod/*` values are placeholders; `jenkins/env/prod.properties` unfilled; real-AWS Terraform (`manage_floci=false`) never run | Phase: real AWS |

---

## 8. Quick reference

```
URLs        web        http://localhost:8080      (login)
            api-gateway http://localhost:8000      (/health, /events, ...)
            argocd      http://localhost:9092
            jenkins     http://localhost:9091
            grafana     http://localhost:9093      (dash uid: phase-f-loadtest)
            prometheus  http://localhost:9094
            jaeger      http://localhost:9095
            k3s API     app_services  https://localhost:6501
                        backing_svcs  https://localhost:6500
            Floci AWS   http://localhost:4566

Images      Floci ECR   172.30.0.20:5000/ai-notification/<svc>:<sha>   (push via localhost:5100)
            Docker Hub  docker.io/dip75016860/ai-notification:<svc>-<sha>

Services    api-gateway identity-service tenant-service event-service ai-service
            rule-engine-service notification-service channel-service template-service
            analytics-service audit-service web prediction-service

Commands    scripts/tf.sh <plan|apply|destroy|...>     always via this wrapper (-parallelism=1)
            scripts/safe-restart.sh                    reconcile after a Docker restart
            bash loadtest/smoke.sh                     pre-flight the API
            caffeinate -i k6 run ... loadtest/*.js     load test (no sleep mid-run)
            bash loadtest/diag.sh                      diagnosis snapshot

State/creds platform-infrastructure/envs/state/{*-admin-password.txt, kubeconfig-*}
Secrets     platform-infrastructure/secrets.local.tfvars   (gitignored, chmod 600)
```
