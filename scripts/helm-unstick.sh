#!/usr/bin/env bash
# Sourced (not executed) right before every `helm upgrade --install` in this
# repo. Usage: source helm-unstick.sh <release> <namespace>
#
# Helm's own release state (a Secret it manages in the target namespace) can
# get stuck "pending-install"/"pending-upgrade"/"pending-rollback" if a
# previous helm operation was interrupted -- killed mid-flight, laptop sleep,
# Ctrl+C, a stray `| head` truncating the pipe terraform apply was running
# through (confirmed live, exactly this way). Every subsequent
# `helm upgrade --install` on that release then fails immediately with
# "another operation (install/upgrade/rollback) is in progress" until
# cleared by hand. Self-healed here instead: uninstall the stuck release so
# the `helm upgrade --install` that follows this script falls into its own
# "does not exist, installing it now" path and does a clean fresh install --
# simpler than hunting for a "last good" revision to roll back to, and this
# repo's whole point is that nothing in the cluster is a source of truth
# git/this script isn't already prepared to recreate.
set -e

_hu_release="$1"
_hu_namespace="$2"

_hu_status=$(helm status "$_hu_release" -n "$_hu_namespace" 2>/dev/null | awk -F': ' '/^STATUS:/{print $2}')
case "$_hu_status" in
  pending-*)
    echo "helm release $_hu_release is stuck in $_hu_status -- uninstalling so the next install starts clean..."
    helm uninstall "$_hu_release" -n "$_hu_namespace" || true
    ;;
esac

unset _hu_release _hu_namespace _hu_status
