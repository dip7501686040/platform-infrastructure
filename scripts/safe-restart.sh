#!/usr/bin/env bash
# Safe bring-up of the Floci stack after Docker Desktop was stopped/restarted.
#
# WHY THIS EXISTS: a Docker Desktop restart kills the k3s node containers
# mid-flight. Every app pod is orphaned at the same instant (exitCode 255,
# STATUS Unknown), and kubelet then tries to cold-start all 13 NestJS
# services at once *while* reconciling ~11 dead pods -- confirmed live, that
# drove this 8GB / 8-core Mac to load average 44 and a swap-thrash
# meltdown. The pods themselves are fine; they just can't all cold-start
# together on this hardware.
#
# This script does what recovered it by hand:
#   1. wait for Docker + both k3s API servers
#   2. pin the app_services k3s node back onto floci-static at .10 if it
#      drifted (Docker doesn't guarantee a container keeps its IP)
#   3. pause ArgoCD auto-sync, scale every ai-notification Deployment to 0
#      BEFORE the pod storm, and clear the orphaned Unknown/Completed pods
#   4. scale the 13 back up in small batches with pauses
#   5. bring ArgoCD + observability back, nudge a sync, verify
#
# Jenkins is left STOPPED on purpose (builds are pushed; no reason to burn
# CPU on it) -- set KEEP_JENKINS=1 to start it too.
#
# Usage:  scripts/safe-restart.sh
# Tunables (env):
#   BATCH_SIZE=3        services scaled up per batch
#   BATCH_SLEEP=50      seconds to wait between batches
#   WITH_OBSERVABILITY=1  start jaeger/prometheus/grafana/otel too (0 to skip)
#   KEEP_JENKINS=0      1 = also start floci-jenkins

set -uo pipefail

BATCH_SIZE="${BATCH_SIZE:-3}"
BATCH_SLEEP="${BATCH_SLEEP:-50}"
WITH_OBSERVABILITY="${WITH_OBSERVABILITY:-1}"
KEEP_JENKINS="${KEEP_JENKINS:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC_APP="$REPO_ROOT/envs/state/kubeconfig-ai-notification-floci"
KC_BACK="$REPO_ROOT/envs/state/kubeconfig-floci-backing-services"

# helm lives in ~/bin, docker+kubectl in Docker Desktop's ~/.docker/bin
export PATH="$HOME/bin:$HOME/.docker/bin:$PATH"

APP_NS="ai-notification"
BACK_NS="backing-services"
APP_K3S_CONTAINER="floci-eks-ai-notification-floci"
BACK_K3S_CONTAINER="floci-eks-floci-backing-services"
APP_K3S_STATIC_IP="172.30.0.10"
FLOCI_NET="floci-static"

# Scale-up order: core request path first, then fan-out, web last (its
# NEXT_PUBLIC_API_URL is baked at build time so it depends on nothing here).
SERVICES=(
  identity-service tenant-service api-gateway
  event-service channel-service audit-service
  ai-service analytics-service rule-engine-service
  notification-service template-service prediction-service
  web
)

ARGOCD_CONTAINERS=(
  floci-argocd-redis floci-argocd-repo-server
  floci-argocd-application-controller
  floci-argocd-applicationset-controller
  floci-argocd-server
)
OBS_CONTAINERS=(floci-otel-collector floci-prometheus floci-grafana floci-jaeger)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
load() { uptime | sed 's/.*averages*: */load /'; }

kapp()  { kubectl --kubeconfig "$KC_APP"  "$@"; }
kback() { kubectl --kubeconfig "$KC_BACK" "$@"; }

# --- 1. Docker daemon ------------------------------------------------------
say "Waiting for the Docker daemon"
if ! docker info >/dev/null 2>&1; then
  info "not responding -- launching Docker Desktop"
  open -a Docker 2>/dev/null || true
fi
for i in $(seq 1 60); do
  docker info >/dev/null 2>&1 && { info "daemon up"; break; }
  sleep 3
  [ "$i" = 60 ] && { echo "Docker never came up" >&2; exit 1; }
done

# --- 2. Floci support containers -----------------------------------------
say "Floci core containers"
# floci-ecr-registry is Floci-managed and has NO restart policy -- it will
# NOT come back on its own after a Docker restart.
for c in floci "$BACK_K3S_CONTAINER" "$APP_K3S_CONTAINER" floci-ecr-registry; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  if [ "$st" = missing ]; then
    info "$c: MISSING -- run 'scripts/tf.sh apply' first"; exit 1
  elif [ "$st" != running ]; then
    docker start "$c" >/dev/null && info "$c: started"
  else
    info "$c: already running"
  fi
done

# Keep Jenkins off unless asked -- unless-stopped may have revived it.
if [ "$KEEP_JENKINS" = 1 ]; then
  docker start floci-jenkins >/dev/null 2>&1 && info "floci-jenkins: started (KEEP_JENKINS=1)"
else
  docker stop floci-jenkins >/dev/null 2>&1 && info "floci-jenkins: stopped (set KEEP_JENKINS=1 to keep it)"
fi

# --- 3. app_services k3s node: pin IP, wait for API ---------------------
say "app_services k3s node ($APP_K3S_CONTAINER)"
cur_ip="$(docker inspect "$APP_K3S_CONTAINER" \
  --format "{{(index .NetworkSettings.Networks \"$FLOCI_NET\").IPAddress}}" 2>/dev/null || true)"
if [ "$cur_ip" != "$APP_K3S_STATIC_IP" ]; then
  info "IP is '${cur_ip:-none}', expected $APP_K3S_STATIC_IP -- reattaching"
  # free the address if something else grabbed it
  holder="$(docker network inspect "$FLOCI_NET" \
    --format "{{range .Containers}}{{.Name}} {{.IPv4Address}}{{\"\\n\"}}{{end}}" \
    | awk -v ip="$APP_K3S_STATIC_IP/" '$2==ip {print $1}')"
  [ -n "$holder" ] && [ "$holder" != "$APP_K3S_CONTAINER" ] && \
    docker network disconnect "$FLOCI_NET" "$holder" >/dev/null 2>&1 && \
    docker network connect "$FLOCI_NET" "$holder" >/dev/null 2>&1 && \
    info "  bumped $holder off $APP_K3S_STATIC_IP"
  docker network disconnect -f "$FLOCI_NET" "$APP_K3S_CONTAINER" >/dev/null 2>&1 || true
  docker network connect --ip "$APP_K3S_STATIC_IP" "$FLOCI_NET" "$APP_K3S_CONTAINER" >/dev/null 2>&1
  docker restart "$APP_K3S_CONTAINER" >/dev/null
  info "  reattached at $APP_K3S_STATIC_IP and restarted"
else
  info "IP OK ($APP_K3S_STATIC_IP)"
fi

wait_api() {
  local kc="$1" name="$2"
  for i in $(seq 1 60); do
    kubectl --kubeconfig "$kc" get --raw /readyz >/dev/null 2>&1 && { info "$name API ready"; return 0; }
    sleep 4
  done
  echo "$name API never became ready" >&2; return 1
}
wait_api "$KC_BACK" "backing_services" || exit 1
wait_api "$KC_APP"  "app_services"     || exit 1

# --- 4. backing services must be Ready before app pods start ------------
say "Backing services (Postgres / RabbitMQ / Redis)"
for i in $(seq 1 45); do
  ready="$(kback get pods -n "$BACK_NS" --no-headers 2>/dev/null | awk '$2=="1/1"||$2=="2/2"{n++} END{print n+0}')"
  total="$(kback get pods -n "$BACK_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  info "ready $ready/$total"
  [ "${ready:-0}" -ge 3 ] && break
  sleep 4
done

# --- 5. pause ArgoCD, scale everything to 0 BEFORE the storm -----------
say "Pausing ArgoCD auto-sync and scaling ai-notification to 0"
docker stop floci-argocd-application-controller floci-argocd-applicationset-controller >/dev/null 2>&1 \
  && info "stopped ArgoCD controllers"
if kapp get ns "$APP_NS" >/dev/null 2>&1; then
  n_dep="$(kapp get deploy -n "$APP_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  kapp scale deploy --all -n "$APP_NS" --replicas=0 >/dev/null 2>&1
  info "scaled ${n_dep:-0} deployments to 0"
else
  info "namespace $APP_NS not found -- has 'scripts/tf.sh apply' run? continuing anyway"
fi

say "Clearing orphaned / finished pods"
kapp delete pods -n "$APP_NS" --field-selector status.phase=Succeeded --grace-period=0 --force >/dev/null 2>&1 || true
kapp delete pods -n "$APP_NS" --field-selector status.phase=Failed    --grace-period=0 --force >/dev/null 2>&1 || true
# 'Unknown' isn't selectable by field-selector -- match by column
orphans="$(kapp get pods -n "$APP_NS" --no-headers 2>/dev/null | awk '$3=="Unknown"||$3=="Error"||$3=="Terminating"{print $1}')"
if [ -n "$orphans" ]; then
  echo "$orphans" | xargs kapp delete pod -n "$APP_NS" --grace-period=0 --force >/dev/null 2>&1 || true
  info "force-deleted: $(echo "$orphans" | tr '\n' ' ')"
fi
kapp delete jobs -n "$APP_NS" --all >/dev/null 2>&1 && info "deleted finished migrate Jobs"
sleep 8

# --- 6. batched scale-up ----------------------------------------------
say "Scaling the 13 services back up (batches of $BATCH_SIZE, ${BATCH_SLEEP}s apart)"
i=0
while [ "$i" -lt "${#SERVICES[@]}" ]; do
  batch=("${SERVICES[@]:$i:$BATCH_SIZE}")
  for d in "${batch[@]}"; do
    kapp scale deploy "$d" -n "$APP_NS" --replicas=1 >/dev/null 2>&1
  done
  info "up: ${batch[*]}"
  i=$((i + BATCH_SIZE))
  [ "$i" -lt "${#SERVICES[@]}" ] || break
  sleep "$BATCH_SLEEP"
  counts="$(kapp get pods -n "$APP_NS" --no-headers 2>/dev/null | awk '{c[$3]++} END{for(k in c) printf "%s=%d ",k,c[k]}')"
  info "  pods: ${counts:-none}   $(load)"
done

# --- 7. restore ArgoCD + observability -------------------------------
say "Restarting ArgoCD (refreshes the target kubeconfig too)"
for c in "${ARGOCD_CONTAINERS[@]}"; do docker restart "$c" >/dev/null 2>&1 && info "restarted $c"; done

if [ "$WITH_OBSERVABILITY" = 1 ]; then
  say "Starting observability"
  for c in "${OBS_CONTAINERS[@]}"; do docker start "$c" >/dev/null 2>&1 && info "started $c"; done
else
  say "Skipping observability (WITH_OBSERVABILITY=0)"
fi

say "Waiting for pods to settle, then nudging an ArgoCD sync"
sleep 45
kapp annotate applications -n argocd --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
sleep 30

# --- 8. verify -------------------------------------------------------
say "Result"
kapp get pods -n "$APP_NS" --no-headers 2>/dev/null | awk '{c[$3]++} END{printf "pods: "; for(k in c) printf "%s=%d ",k,c[k]; print ""}'
echo
printf 'ArgoCD applications:\n'
kapp get applications -n argocd --no-headers -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null | sed 's/^/  /'
echo
printf 'Public URLs:\n'
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
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null)"
  printf '  %-12s %s  %s\n' "$n" "$code" "$url"
done
echo
load
echo
echo "Done. If any app is still OutOfSync/Missing, give it a minute or run:"
echo "  kubectl --kubeconfig $KC_APP -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite"
