#!/usr/bin/env bash
#
# bootstrap/clustermesh-connect.sh
#
# Connects every pair of registered clusters into a full Cilium Cluster
# Mesh. Imperative by nature (needs simultaneous kubeconfig context access
# to two clusters at once via `cilium clustermesh connect`) — cannot be
# expressed as GitOps, same category as register-with-hub.sh.tpl.
#
# Run manually after, on every cluster you're passing in:
#   1. Cilium (wave "10") is healthy and clustermesh.useAPIServer is up
#   2. cert-manager (wave "20") + External Secrets (wave "20") are healthy
#   3. platform/clustermesh's CA has synced (wave "25") — check
#      `kubectl get certificate -n cert-manager` shows clustermesh certs
#      Ready, not Pending, on that cluster
#   4. That cluster's kubeconfig context is available locally, named to
#      match its Cilium cluster.name value (hub, spoke-dev-k8s, ...) — see
#      platform/values/hub/cilium.yaml and the cluster-mesh-id label in
#      argocd/clusters/<name>.yaml
#
# Usage:
#   ./bootstrap/clustermesh-connect.sh hub spoke-dev-k8s [spoke-3 ...]
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <context1> <context2> [context3 ...]"
  echo "  Each <contextN> must be a kubectl context name matching that"
  echo "  cluster's Cilium cluster.name."
  exit 1
fi

CONTEXTS=("$@")

echo "==> Verifying cilium CLI can see clustermesh status on each cluster..."
for ctx in "${CONTEXTS[@]}"; do
  echo "  - ${ctx}"
  cilium clustermesh status --context "${ctx}" --wait --wait-duration 2m
done

echo "==> Connecting every pair (full mesh, N*(N-1)/2 links)..."
for ((i = 0; i < ${#CONTEXTS[@]}; i++)); do
  for ((j = i + 1; j < ${#CONTEXTS[@]}; j++)); do
    a="${CONTEXTS[$i]}"
    b="${CONTEXTS[$j]}"
    echo "  -> ${a} <-> ${b}"
    cilium clustermesh connect --context "${a}" --destination-context "${b}"
  done
done

echo "==> Final status check on every cluster..."
for ctx in "${CONTEXTS[@]}"; do
  cilium clustermesh status --context "${ctx}"
done

echo "Done. Verify with: cilium connectivity test --multi-cluster <other-context>"
