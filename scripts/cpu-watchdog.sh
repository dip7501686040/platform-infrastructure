#!/usr/bin/env bash
# Continuous, self-healing enforcement of "CPU never goes into uncontrolled
# concurrent contention, public URLs stay live even after a container/pod
# restart, delay is acceptable in exchange for that."
#
# WHY THIS EXISTS, not just cpu-priority.sh's per-call snapshot: that script
# only sets caps at the INSTANT something sources kubeconfig.sh -- it has no
# opinion between calls, and nothing enforces that only one such call is
# ever in flight at a time. Confirmed live, twice: Terraform's default
# parallelism (10) can genuinely run two different -target resources'
# provisioners concurrently, each sourcing kubeconfig.sh for a DIFFERENT
# cluster, each setting caps that immediately contradict the other's --
# combined host load hit 8.81 on this 8-core Mac from exactly this, not
# from any single container's cap being too generous. And a cap alone does
# nothing for a cluster that's already crash-looped or lost its ALB target
# health *between* applies, when nothing is sourcing kubeconfig.sh at all --
# which is the actual common case for "is the public URL up," since that's
# almost all wall-clock time.
#
# This script is the missing piece: a persistent loop that
#   1. treats ALB target health (already polled by the emulated ALB every
#      30s regardless of real user traffic) as the source of truth for
#      "does this cluster need to be healthy right now" -- not "did
#      Terraform just touch it"
#   2. boosts AT MOST ONE cluster at a time to its proven recovery cap
#      (same numbers cpu-priority.sh's LIVE tier uses -- these are the
#      values already confirmed live to actually fix each cluster, not
#      guesses), holds it there until its targets go healthy or a hard
#      ceiling on wait time is hit, then drops it back to its floor and
#      moves to the next unhealthy one -- true serialization, not "everyone
#      gets a slice"
#   3. re-applies the correct static-IP/CPU-cap pin on every pass anyway
#      (calling cpu-priority.sh's floor logic each tick), so a container
#      that got restarted (crash, `docker restart`, a Mac sleep/wake cycle)
#      is caught and re-capped automatically instead of silently running
#      unthrottled until the next Terraform apply happens to touch it
#
# Run this once, in the background, for as long as you want the "always
# live" guarantee to actually hold -- see the bottom of this file for how
# to install it as a launchd agent so it also survives a reboot.
#
# Usage: scripts/cpu-watchdog.sh [--once]
#   --once   run a single pass and exit (for testing/manual invocation)

set -u

_wd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_wd_root="$(cd "$_wd_dir/.." && pwd)"
_wd_log="$_wd_root/envs/state/cpu-watchdog.log"
mkdir -p "$(dirname "$_wd_log")"

# Self-contained: this is meant to run detached (launchd, nohup, a plain
# background shell that outlives the terminal that started it), so it
# can't rely on the caller having already sourced local/floci-env.sh --
# same AWS_PROFILE=floci setup every `aws elbv2` call here needs.
source "$_wd_root/local/floci-env.sh"

_wd_log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" | tee -a "$_wd_log"
}

# cluster-name -> container-name, and cluster-name -> space-separated list
# of target-group names it owns. backing_services has no public ALB target
# (internal-only), so it's covered by cpu-priority.sh's floor/co-active
# logic but never itself picked as "the neediest" here.
#
# jenkins/argocd/observability dropped from this list entirely -- they're
# plain Docker containers now, not their own EKS-emulated cluster (see
# main.tf's own comment on that pivot: 5 separate k3s control planes was
# the actual root cause of the CPU/Docker-Desktop-crash incidents this
# watchdog exists to catch, not something CPU-capping alone could fully
# fix). They have no ALB target group to poll anymore either (direct host
# ports). The class of problem this watchdog exists for -- a k3s node
# CPU-starved into probe-timeout crash-loops -- doesn't apply to a single
# plain container the same way; Docker's own `restart: unless-stopped`
# already covers "comes back after a crash" for them.
_wd_clusters="app_services backing_services"

_wd_container() {
  case "$1" in
    app_services)     echo "floci-eks-ai-notification-floci" ;;
    backing_services) echo "floci-eks-floci-backing-services" ;;
  esac
}

_wd_target_groups() {
  case "$1" in
    app_services) echo "web-tg api-gateway-tg" ;;
    *)            echo "" ;;
  esac
}

# How long (seconds) to hold one cluster boosted before giving up on this
# pass and moving on regardless -- prevents one stubbornly-unhealthy
# cluster from starving every other one's turn forever. Generous, per "delay
# is acceptable": would rather wait than declare failure early and thrash.
_wd_boost_timeout=90
_wd_poll_interval=15

_wd_tg_unhealthy() {
  local tg="$1" arn state
  arn=$(aws elbv2 describe-target-groups --names "$tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || return 1
  [ -z "$arn" ] || [ "$arn" = "None" ] && return 1
  state=$(aws elbv2 describe-target-health --target-group-arn "$arn" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null)
  [ "$state" != "healthy" ]
}

_wd_cluster_needs_boost() {
  local cluster="$1" tg
  for tg in $(_wd_target_groups "$cluster"); do
    if _wd_tg_unhealthy "$tg"; then
      return 0
    fi
  done
  return 1
}

_wd_container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# No exceptions left in this list now that it's just app_services/
# backing_services (jenkins is a plain container outside this watchdog's
# scope now, see _wd_clusters' own comment -- it's fine for it to sit
# stopped on request without this watchdog overriding that). Kept as a
# function (always false) rather than deleted outright so a future
# deliberate exception has an obvious place to go.
_wd_leave_stopped() {
  return 1
}

_wd_one_pass() {
  # Floor pass first: re-assert every container's correct cap unconditionally
  # (cpu-priority.sh with no active target = everyone at their floor). This
  # is what catches a plain `docker restart` or crash-recovery that
  # otherwise wouldn't get re-capped until the next Terraform apply.
  "$_wd_dir/cpu-priority.sh" "__none__" >/dev/null 2>&1 || true

  local cluster needy=""
  for cluster in $_wd_clusters; do
    local c
    c=$(_wd_container "$cluster")
    if ! _wd_container_running "$c"; then
      if _wd_leave_stopped "$cluster"; then
        continue
      fi
      _wd_log "$cluster ($c) is stopped -- restarting (this cluster is not on the leave-stopped list)"
      docker start "$c" >/dev/null 2>&1 || true
      # Give it a moment to actually come up before deciding whether it
      # still needs a boost -- an ALB health check against a container that
      # only just started would read as unhealthy regardless of CPU cap.
      sleep 5
    fi
    if _wd_cluster_needs_boost "$cluster"; then
      needy="$cluster"
      break
    fi
  done

  if [ -z "$needy" ]; then
    return 0
  fi

  local c
  c=$(_wd_container "$needy")
  _wd_log "boosting $needy ($c) -- target group unhealthy"
  "$_wd_dir/cpu-priority.sh" "$c" >/dev/null 2>&1 || true

  local waited=0
  while [ "$waited" -lt "$_wd_boost_timeout" ]; do
    if ! _wd_cluster_needs_boost "$needy"; then
      _wd_log "$needy recovered after ${waited}s -- dropping back to floor"
      "$_wd_dir/cpu-priority.sh" "__none__" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  _wd_log "$needy still unhealthy after ${_wd_boost_timeout}s -- moving on this pass, will retry next tick"
  "$_wd_dir/cpu-priority.sh" "__none__" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--once" ]; then
  _wd_log "cpu-watchdog: single pass"
  _wd_one_pass
  exit 0
fi

_wd_log "cpu-watchdog: starting continuous loop (poll every ${_wd_poll_interval}s, boost timeout ${_wd_boost_timeout}s)"
while true; do
  _wd_one_pass
  sleep "$_wd_poll_interval"
done
