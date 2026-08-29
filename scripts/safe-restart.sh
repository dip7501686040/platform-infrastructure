#!/usr/bin/env bash
# Idempotent reconcile of the Floci stack back to healthy -- WITHOUT touching
# anything that is already running fine.
#
# WHY: a Docker Desktop restart (or `docker stop` of the floci-eks-* nodes)
# orphans every app pod at the same instant. Letting kubelet cold-start all
# 13 NestJS services at once -- while it also reconciles the dead pods --
# spiked this 8GB / 8-core Mac to load average 44 and a swap-thrash
# meltdown. The pods are NOT broken; they just can't all cold-start together.
#
# This script only acts on what is actually wrong:
#   - starts Floci / k3s / ArgoCD / observability containers that are STOPPED
#     (running ones are left completely alone)
#   - re-pins the app_services k3s node to 172.30.0.10 only if it drifted
#   - deletes orphaned Unknown/Error/CrashLoop/ImagePull/Completed pods and
#     finished Jobs (never touches a Running pod)
#   - finds ai-notification Deployments that are NOT fully ready, scales just
#     those to 0, then brings them back BATCH_SIZE at a time, BATCH_SLEEP
#     apart, so CPU never spikes. Healthy Deployments are not scaled at all.
#   - restarts the ArgoCD controllers ONLY if they are visibly wedged
#   - leaves Jenkins exactly as-is (STOP_JENKINS=1 to force it down)
#
# If it had to (re)start the app_services k3s node itself, every pod is
# cold-starting regardless, so all 13 are put through the batched path.
#
# Usage: scripts/safe-restart.sh
# Env:
#   BATCH_SIZE=3         Deployments brought up per batch
#   BATCH_SLEEP=50       seconds between batches
#   WITH_OBSERVABILITY=1 also start stopped jaeger/prometheus/grafana/otel
#   STOP_JENKINS=0       1 = stop floci-jenkins if it is running
#   FORCE_ALL=0          1 = batch-restart all 13 even if they look healthy

set -uo pipefail

BATCH_SIZE="${BATCH_SIZE:-3}"
BATCH_SLEEP="${BATCH_SLEEP:-50}"
WITH_OBSERVABILITY="${WITH_OBSERVABILITY:-1}"
STOP_JENKINS="${STOP_JENKINS:-0}"
FORCE_ALL="${FORCE_ALL:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC_APP="$REPO_ROOT/envs/state/kubeconfig-ai-notification-floci"
KC_BACK="$REPO_ROOT/envs/state/kubeconfig-floci-backing-services"
export PATH="$HOME/bin:$HOME/.docker/bin:$PATH"   # helm in ~/bin, docker/kubectl in ~/.docker/bin

APP_NS="ai-notification"
BACK_NS="backing-services"
APP_K3S="floci-eks-ai-notification-floci"
BACK_K3S="floci-eks-floci-backing-services"
APP_K3S_IP="172.30.0.10"
NET="floci-static"

ARGOCD_CTRLS=(floci-argocd-application-controller floci-argocd-applicationset-controller)
ARGOCD_ALL=(floci-argocd-redis floci-argocd-repo-server "${ARGOCD_CTRLS[@]}" floci-argocd-server)
OBS=(floci-otel-collector floci-prometheus floci-grafana floci-jaeger)

# Scale-up order: core request path first, web last (nothing here depends on it).
SERVICES=(
  identity-service tenant-service api-gateway
  event-service channel-service audit-service
  ai-service analytics-service rule-engine-service
  notification-service template-service prediction-service
  web
)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
load() { uptime | sed 's/.*averages*: */load /'; }
kapp()  { kubectl --kubeconfig "$KC_APP"  "$@"; }
kback() { kubectl --kubeconfig "$KC_BACK" "$@"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
pod_counts() { kapp get pods -n "$APP_NS" --no-headers 2>/dev/null \
  | awk '{c[$3]++} END{for(k in c) printf "%s=%d ",k,c[k]}'; }

# start $1 only if it exists and is stopped. echo: started | running | missing
start_if_stopped() {
  if ! docker inspect "$1" >/dev/null 2>&1; then echo missing; return; fi
  if running "$1"; then echo running; return; fi
  docker start "$1" >/dev/null 2>&1 && echo started || echo failed
}

# ---------------------------------------------------------------- 1. Docker
say "Docker daemon"
if ! docker info >/dev/null 2>&1; then
  info "not responding -- launching Docker Desktop"; open -a Docker 2>/dev/null || true
fi
for i in $(seq 1 60); do
  docker info >/dev/null 2>&1 && { info "up"; break; }
  [ "$i" = 60 ] && { echo "Docker never came up" >&2; exit 1; }
  sleep 3
done

# -------------------------------------------------- 2. core containers (start only if stopped)
say "Core containers (only stopped ones are started)"
for c in floci floci-ecr-registry "$BACK_K3S" "$APP_K3S"; do
  r="$(start_if_stopped "$c")"
  [ "$r" = missing ] && { echo "$c is MISSING -- run scripts/tf.sh apply first" >&2; exit 1; }
  info "$c: $r"
done
# Did WE just (re)start the app_services node? true if its StartedAt is
# within the last 90s. If the date parse fails we fall back to 0 -- the
# per-Deployment health check below still catches every pod that is down,
# so correctness doesn't depend on this flag, only the upfront scale-to-0.
started_app_k3s=0
if running "$APP_K3S"; then
  _sa="$(docker inspect -f '{{.State.StartedAt}}' "$APP_K3S" 2>/dev/null | cut -c1-19)"
  _sae="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$_sa" +%s 2>/dev/null || echo 0)"
  _age=$(( $(date +%s) - _sae ))
  [ "$_sae" != 0 ] && [ "$_age" -ge 0 ] && [ "$_age" -lt 90 ] && started_app_k3s=1
fi

if [ "$STOP_JENKINS" = 1 ] && running floci-jenkins; then
  docker stop floci-jenkins >/dev/null 2>&1 && info "floci-jenkins: stopped (STOP_JENKINS=1)"
else
  running floci-jenkins && info "floci-jenkins: left running" || info "floci-jenkins: left stopped"
fi

# ------------------------------------------------ 3. app_services k3s: pin IP if drifted
say "app_services k3s node IP"
cur="$(docker inspect "$APP_K3S" --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" 2>/dev/null || true)"
if [ "$cur" = "$APP_K3S_IP" ]; then
  info "OK ($APP_K3S_IP)"
else
  info "is '${cur:-none}', want $APP_K3S_IP -- reattaching"
  holder="$(docker network inspect "$NET" \
    --format "{{range .Containers}}{{.Name}} {{.IPv4Address}}{{\"\\n\"}}{{end}}" \
    | awk -v want="$APP_K3S_IP/" '$2==want{print $1}')"
  if [ -n "$holder" ] && [ "$holder" != "$APP_K3S" ]; then
    docker network disconnect "$NET" "$holder" >/dev/null 2>&1
    docker network connect "$NET" "$holder" >/dev/null 2>&1
    info "  bumped $holder off $APP_K3S_IP"
  fi
  docker network disconnect -f "$NET" "$APP_K3S" >/dev/null 2>&1 || true
  docker network connect --ip "$APP_K3S_IP" "$NET" "$APP_K3S" >/dev/null 2>&1
  docker restart "$APP_K3S" >/dev/null && started_app_k3s=1
  info "  reattached + restarted"
fi

# --------------------------------------------------------- 4. wait for k3s APIs (only if not up)
say "k3s API servers"
wait_api() {
  kubectl --kubeconfig "$1" get --raw /readyz >/dev/null 2>&1 && { info "$2: already up"; return 0; }
  for i in $(seq 1 60); do
    kubectl --kubeconfig "$1" get --raw /readyz >/dev/null 2>&1 && { info "$2: ready"; return 0; }
    sleep 4
  done
  echo "$2 API never became ready" >&2; return 1
}
wait_api "$KC_BACK" backing_services || exit 1
wait_api "$KC_APP"  app_services     || exit 1

# ----------------------------------------- 5. backing services must be ready before app pods
say "Backing services (Postgres / RabbitMQ / Redis)"
for i in $(seq 1 45); do
  r="$(kback get pods -n "$BACK_NS" --no-headers 2>/dev/null \
       | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]+0>0 && $3=="Running") n++} END{print n+0}')"
  info "ready $r/3"
  [ "${r:-0}" -ge 3 ] && break
  sleep 4
done

# --------------------------------------------------- 6. ArgoCD + observability: start stopped only
say "ArgoCD containers (start stopped only)"
for c in "${ARGOCD_ALL[@]}"; do info "$c: $(start_if_stopped "$c")"; done

if [ "$WITH_OBSERVABILITY" = 1 ]; then
  say "Observability (start stopped only)"
  for c in "${OBS[@]}"; do info "$c: $(start_if_stopped "$c")"; done
fi

# ---------------------------------------------------- 7. which app Deployments need reconciling
say "Assessing ai-notification Deployments"
if ! kapp get ns "$APP_NS" >/dev/null 2>&1; then
  echo "namespace $APP_NS not found -- run scripts/tf.sh apply" >&2; exit 1
fi

UNHEALTHY=()
if [ "$started_app_k3s" = 1 ] || [ "$FORCE_ALL" = 1 ]; then
  reason=$([ "$FORCE_ALL" = 1 ] && echo "FORCE_ALL=1" || echo "app_services k3s was (re)started -- every pod is cold-starting")
  info "$reason -> all ${#SERVICES[@]} services go through the batched path"
  kapp scale deploy --all -n "$APP_NS" --replicas=0 >/dev/null 2>&1
  UNHEALTHY=("${SERVICES[@]}")
else
  while read -r name spec ready; do
    [ -z "$name" ] && continue
    [ "$ready" = "<none>" ] && ready=0
    if [ "${spec:-0}" -lt 1 ] || [ "${ready:-0}" != "${spec:-0}" ]; then
      UNHEALTHY+=("$name")
    fi
  done < <(kapp get deploy -n "$APP_NS" --no-headers \
             -o custom-columns=N:.metadata.name,S:.spec.replicas,R:.status.readyReplicas 2>/dev/null)
  if [ "${#UNHEALTHY[@]}" -gt 0 ]; then
    info "not ready: ${UNHEALTHY[*]}"
    # stop their ReplicaSets recreating pods so the batched 0->1 is the only cold-start
    kapp scale deploy -n "$APP_NS" --replicas=0 "${UNHEALTHY[@]}" >/dev/null 2>&1
  else
    info "all Deployments are fully ready"
  fi
fi

# --------------------------------------------------------------- 8. clean orphaned pods + Jobs
say "Cleaning orphaned pods and finished Jobs (Running pods untouched)"
kapp delete pods -n "$APP_NS" --field-selector status.phase=Succeeded --grace-period=0 --force >/dev/null 2>&1 || true
bad="$(kapp get pods -n "$APP_NS" --no-headers 2>/dev/null \
  | awk '{s=$3} s ~ /^(Unknown|Error|Completed|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|Evicted|NodeLost|Terminating|Failed)$/ {print $1}')"
if [ -n "$bad" ]; then
  echo "$bad" | xargs kapp delete pod -n "$APP_NS" --grace-period=0 --force >/dev/null 2>&1 || true
  info "removed: $(echo "$bad" | tr '\n' ' ')"
else
  info "no orphaned pods"
fi
donejobs="$(kapp get jobs -n "$APP_NS" --no-headers 2>/dev/null | awk '$2=="Complete" || $3=="1/1"{print $1}')"
if [ -n "$donejobs" ]; then
  echo "$donejobs" | xargs kapp delete job -n "$APP_NS" >/dev/null 2>&1 || true
  info "deleted finished Jobs: $(echo "$donejobs" | tr '\n' ' ')"
fi

# --------------------------------------------------------------------- 9. batched bring-up
if [ "${#UNHEALTHY[@]}" -eq 0 ]; then
  say "Nothing to reconcile -- every ai-notification Deployment is already healthy"
else
  say "Bringing up ${#UNHEALTHY[@]} Deployment(s), $BATCH_SIZE at a time, ${BATCH_SLEEP}s apart"
  idx=0
  total=${#UNHEALTHY[@]}
  while [ "$idx" -lt "$total" ]; do
    batch=("${UNHEALTHY[@]:$idx:$BATCH_SIZE}")
    for d in "${batch[@]}"; do kapp scale deploy "$d" -n "$APP_NS" --replicas=1 >/dev/null 2>&1; done
    info "batch: ${batch[*]}"
    idx=$((idx + BATCH_SIZE))
    [ "$idx" -lt "$total" ] || break
    sleep "$BATCH_SLEEP"
    info "  pods: $(pod_counts)  $(load)"
  done
fi

# ------------------------------------- 10. restart ArgoCD controllers only if visibly wedged
say "ArgoCD controller health"
wedged="$(docker logs --since 3m floci-argocd-application-controller 2>&1 \
  | grep -cE 'Unauthorized|connection refused|dial tcp|x509' || true)"
if ! running floci-argocd-application-controller; then
  info "app-controller not running -- (re)starting"
  for c in "${ARGOCD_CTRLS[@]}"; do docker start "$c" >/dev/null 2>&1; done
elif [ "${wedged:-0}" -ge 8 ]; then
  info "app-controller logging $wedged errors in 3m -- restarting controllers"
  for c in "${ARGOCD_CTRLS[@]}"; do docker restart "$c" >/dev/null 2>&1; done
else
  info "healthy -- left alone (${wedged:-0} errors/3m)"
fi

# ---------------------------------------------------------------------------- 11. verify
if [ "${#UNHEALTHY[@]}" -gt 0 ]; then
  say "Settling + nudging ArgoCD to re-sync the reconciled apps"
  sleep 45
  for d in "${UNHEALTHY[@]}"; do
    kapp -n argocd annotate application "$d" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done
  sleep 25
fi

say "Result"
printf 'pods:  '; pod_counts; echo
echo
echo 'ArgoCD applications:'
kapp get applications -n argocd --no-headers \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null | sed 's/^/  /'
echo
echo 'Public URLs:'
urls=(
  "web         http://localhost:8080/login"
  "api-gateway http://localhost:8000/health"
  "argocd      http://localhost:9092/healthz"
)
[ "$WITH_OBSERVABILITY" = 1 ] && urls+=(
  "grafana     http://localhost:9093/api/health"
  "prometheus  http://localhost:9094/-/healthy"
  "jaeger      http://localhost:9095/"
)
for u in "${urls[@]}"; do
  n="${u%% *}"; url="${u##* }"
  printf '  %-12s %s  %s\n' "$n" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null)" "$url"
done
echo
load
