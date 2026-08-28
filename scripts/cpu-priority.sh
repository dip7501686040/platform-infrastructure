#!/usr/bin/env bash
# Sourced by kubeconfig.sh at the top of EVERY single Terraform-driven
# kubectl/helm operation against any cluster.
#
# FOURTH REVISION -- this used to be a real CPU-arbitration system: an
# "active" cluster got boosted, every other floci-eks-* cluster got held to
# a tier-appropriate floor, because there were 5 separate k3s control
# planes on this Mac all fighting for the same 8 cores (confirmed live:
# combined load hit 300-1300%, and once, a full Docker Desktop crash).
#
# That problem is now solved architecturally, not by CPU-capping harder --
# jenkins/argocd/observability were rebuilt as plain Docker containers
# (see main.tf's own comment on that pivot), not their own EKS-emulated
# clusters. Combined they use low single-digit % CPU. There are only TWO
# floci-eks-* containers left: app_services and backing_services -- and
# they're not competing rivals to arbitrate between, they're the two
# clusters this whole project exists to load-test. Confirmed live: even
# with the old caps' generous "active" values (2.0 / 1.0), routine kubectl
# calls against them were sluggish for no CPU-contention reason visible in
# `docker stats` -- the caps themselves, sized for a 5-cluster world, were
# the bottleneck once that world no longer existed. Fix: give them the
# host, not a bigger slice of it.
#
# So this script now does exactly two things:
#   - keeps floci (the ALB emulator) and floci-ecr-registry pinned to their
#     own small proven-necessary caps (unrelated to the multi-cluster
#     story -- floci needs ~0.8 to actually process HTTP traffic, not just
#     hold a TCP connection open, confirmed live; the registry barely uses
#     any)
#   - gives every floci-eks-* container it finds a cap equal to the full
#     host core count -- currently just app_services and backing_services,
#     but written to apply to whichever floci-eks-* containers exist
#     rather than hardcoding those two names, so a future third real
#     cluster doesn't silently stay capped by omission.
#
# `docker update --cpus=N` sets a real cgroup cpu.max quota. `--cpus=0` is
# NOT "remove the limit" -- confirmed live, Docker silently no-ops it,
# leaving whatever cap was already set (checked via
# `cat /sys/fs/cgroup/cpu.max` inside the container, not just `docker
# inspect`'s HostConfig, which showed CpuQuota/CpuPeriod as cleared while
# the live cgroup was still enforcing the old value). Setting the cap to
# the host's actual core count instead is the correct way to get
# "effectively unlimited" -- the container can never use more than that
# anyway, and it's a value Docker actually applies.
#
# Usage: source cpu-priority.sh <active-container-name>
# (the argument is accepted for backward compatibility with every existing
# caller -- kubeconfig.sh, scripts/cpu-watchdog.sh -- but unused now; there
# is no more "active" concept to apply it to.)

set -e

_cp_active="${1:-}"

_cp_floci="0.8"
_cp_registry="0.05"
# nproc, not a hardcoded guess -- stays correct if this ever runs on a
# different-core-count machine.
_cp_host_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)

docker update --cpus="$_cp_floci" floci >/dev/null 2>&1 || true
docker update --cpus="$_cp_registry" floci-ecr-registry >/dev/null 2>&1 || true

for c in $(docker ps -a --filter "name=floci-eks-" --format '{{.Names}}'); do
  docker update --cpus="$_cp_host_cores" "$c" >/dev/null 2>&1 || true
done

unset _cp_active _cp_floci _cp_registry _cp_host_cores c
