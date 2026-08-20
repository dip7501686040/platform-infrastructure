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
set -e

_kc_cluster_name="$1"
_kc_cluster_endpoint="$2"

echo "waiting for k3s API on ${_kc_cluster_endpoint}..."
for i in $(seq 1 30); do
  if docker exec "floci-eks-${_kc_cluster_name}" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
    break
  fi
  sleep 2
done

KUBECONFIG="$(dirname "${BASH_SOURCE[0]}")/../envs/state/kubeconfig"
docker exec "floci-eks-${_kc_cluster_name}" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s|https://127.0.0.1:6443|${_kc_cluster_endpoint}|" \
  > "$KUBECONFIG"
export KUBECONFIG

for i in $(seq 1 30); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done

unset _kc_cluster_name _kc_cluster_endpoint
