#!/usr/bin/env bash
# Sourced (not executed) by every Floci local-exec provisioner that needs
# kubectl/helm against the floci-eks-<cluster> container's k3s API. Waits for
# the API to actually be up, then sets KUBECONFIG in the calling shell.
#
# Usage: source kubeconfig.sh <cluster_name> <cluster_endpoint>
#
# Pulled out of k8s_reconcile/app_secrets/argocd_install/argocd_manifests
# (main.tf), which all repeated this same "docker exec ... k3s.yaml | sed ...
# > kubeconfig" block — single-sourced here instead.
#
# Writes to envs/state/kubeconfig-<cluster_name>, not one shared
# envs/state/kubeconfig — now that jenkins/argocd/observability/app_services
# are 4 separate clusters, a single shared file meant whichever cluster last
# called this script silently won it, with no way for a human (or a script
# targeting more than one cluster in the same apply) to reliably address a
# specific one. Each cluster now gets its own stable path:
#   export KUBECONFIG=~/platform-infrastructure/envs/state/kubeconfig-floci-jenkins
#   export KUBECONFIG=~/platform-infrastructure/envs/state/kubeconfig-floci-argocd
#   export KUBECONFIG=~/platform-infrastructure/envs/state/kubeconfig-floci-observability
#   export KUBECONFIG=~/platform-infrastructure/envs/state/kubeconfig-ai-notification-floci
# (the suffix is each cluster's cluster_name from envs/local.tfvars, not its
# var.clusters map key — matches the $1 this script is actually called
# with). No caller in main.tf hardcodes the old shared filename — every one
# of them only relies on the exported KUBECONFIG env var this script sets in
# the calling shell, not the path itself — so this rename needed no other
# changes.
set -e

_kc_cluster_name="$1"
_kc_cluster_endpoint="$2"
_kc_container="floci-eks-${_kc_cluster_name}"

# Boosts this cluster's own CPU ceiling and throttles every OTHER
# floci-eks-* container down to a bare-minimum share -- see
# cpu-priority.sh's own comment for the full story (hard cgroup quotas via
# `docker update --cpus`, sized so combined usage across every cluster
# stays ~200% even in the worst case). Every terraform_data resource in
# this repo sources this script as its first action, so this single call
# is what makes "whichever cluster is actively being worked on gets CPU
# priority, every other one waits" apply automatically everywhere, without
# each install step needing its own copy of this logic.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cpu-priority.sh" "$_kc_container"

# Every consumer of this script (k8s_reconcile, argocd_install,
# jenkins_install, app_secrets, every tunnel) assumed this container was
# already running -- confirmed live, a manual `docker stop` (or a Docker
# Desktop restart that doesn't auto-restart a container that was
# deliberately stopped) left every one of them failing with "container ...
# is not running" instead of just... starting it, which is exactly the
# self-healing this whole file already does for the container's *restart
# policy* (see ensure_restart_policies in main.tf) but not for its actual
# running state. Fixed once, here, for every consumer at once rather than
# in each of them separately.
if [ "$(docker inspect -f '{{.State.Running}}' "$_kc_container" 2>/dev/null)" != "true" ]; then
  echo "$_kc_container isn't running -- starting it..."
  docker start "$_kc_container" >/dev/null
fi

# k3s persists node registration -- including the container's own internal
# Docker IP -- to the /var/lib/rancher/k3s volume. Docker doesn't guarantee
# this container the same internal IP across restarts (no fixed IP is
# configured for it; that's Floci's call when it creates the container, not
# ours), so a plain Docker Desktop restart can hand it a different one.
# k3s then fatals on every subsequent start with "failed to find interface
# with specified node ip" -- confirmed live, a genuine crash loop, not
# resource contention: execDuration=11s, exitCode=1, every single cycle,
# forever, since the stale IP is baked into the state it keeps reading back.
# No amount of waiting fixes that. Detected and wiped here instead --
# rancher/k3s:latest is already pulled (it's this container's own image),
# so no new image dependency. Safe specifically because of how this cluster
# is used: ArgoCD (re-installed/re-synced unconditionally by argocd_install/
# argocd_manifests regardless of whether this ever triggers) rebuilds
# everything from platform-gitops onto whatever fresh node identity results
# -- nothing in this cluster is itself a source of truth, git is.
# Detected via RestartCount stability, not log-content matching: confirmed
# live, a `docker logs --tail 3` check taken at the wrong instant (a lucky
# brief "up" window mid-crash-loop, each cycle is only ~11s) can miss an
# actively still-looping container entirely, letting this whole script
# proceed as if healthy while the container keeps dying underneath it. A
# real container-restart count climbing over a short observation window is
# unambiguous regardless of exactly when the check lands. Looped, not
# one-shot, for the same reason: a single wipe-and-restart can land k3s on a
# fresh IP that matches at that instant, only for the container to restart
# again shortly after (this Mac has been genuinely unstable under load all
# session) and draw a *different* IP that mismatches all over again.
for _kc_wipe_attempt in 1 2 3 4 5; do
  _kc_rc_before=$(docker inspect "$_kc_container" --format '{{.RestartCount}}' 2>/dev/null || echo -1)
  sleep 15
  _kc_rc_after=$(docker inspect "$_kc_container" --format '{{.RestartCount}}' 2>/dev/null || echo -1)
  if [ "$_kc_rc_after" = "$_kc_rc_before" ]; then
    break
  fi
  echo "k3s container restarting repeatedly (attempt ${_kc_wipe_attempt}/5, RestartCount $_kc_rc_before -> $_kc_rc_after) -- wiping its persisted state for a clean re-init..."
  docker stop "$_kc_container" >/dev/null 2>&1 || true
  docker run --rm --entrypoint sh -v "${_kc_container}:/data" rancher/k3s:latest -c 'rm -rf /data/*' >/dev/null
  docker start "$_kc_container" >/dev/null
  sleep 5
done
unset _kc_wipe_attempt _kc_rc_before _kc_rc_after

echo "waiting for k3s API on ${_kc_cluster_endpoint}..."
for i in $(seq 1 30); do
  if docker exec "$_kc_container" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
    break
  fi
  sleep 2
done

KUBECONFIG="$(dirname "${BASH_SOURCE[0]}")/../envs/state/kubeconfig-${_kc_cluster_name}"
export KUBECONFIG

# insecure-skip-tls-verify instead of trusting the embedded CA cert:
# confirmed live, repeatedly, kubectl/helm calls against this kubeconfig
# intermittently fail with "x509: certificate signed by unknown authority"
# even seconds after a fresh `docker exec ... cat k3s.yaml` re-fetch -- ruled
# out a stale/truncated read (retrying the fetch itself didn't reliably fix
# it either). Root cause not fully pinned down, but this is a disposable,
# purely-local dev cluster with no real trust boundary to uphold, so
# skip verification entirely rather than keep chasing a cert-matching race
# that self-healing every apply doesn't actually need to solve.
for i in $(seq 1 30); do
  docker exec "$_kc_container" cat /etc/rancher/k3s/k3s.yaml \
    | sed "s|https://127.0.0.1:6443|${_kc_cluster_endpoint}|" \
    | sed '/certificate-authority-data:/d' \
    | sed 's|server: https://|insecure-skip-tls-verify: true\n    server: https://|' \
    > "$KUBECONFIG"
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done

unset _kc_cluster_name _kc_cluster_endpoint _kc_container
