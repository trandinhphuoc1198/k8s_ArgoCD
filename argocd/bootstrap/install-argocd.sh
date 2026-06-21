#!/usr/bin/env bash
#
# argocd/bootstrap/install-argocd.sh
#
# The only two things you install by hand on this cluster:
#   1. Cilium (CNI) — Argo CD's own pods need pod networking to come up,
#      so this can't be handled by Argo CD itself (chicken-and-egg).
#   2. Argo CD — everything after this point (autoscaler, EBS CSI,
#      ingress-nginx, observability stack, KEDA, CNPG, the app, and
#      ongoing management of Cilium itself) is handled by Argo CD via
#      the root Application (argocd/root-app.yaml).
#
# Pinned to the exact same chart version + values file as
# argocd/apps/00-cilium.yaml on purpose — so when Argo CD takes over
# management of Cilium right after this, it sees no diff and does a
# no-op reconcile instead of an unplanned upgrade.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARGOCD_DIR="$REPO_ROOT/argocd"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}"   # leave empty for latest; pin once you've verified it

CILIUM_VERSION="${CILIUM_VERSION:-1.16.0}"          # must match argocd/apps/00-cilium.yaml
# Only needed if cilium-values.yaml's k8sServiceHost: "auto" can't self-detect
# the control-plane endpoint on your setup. Leave unset to use the values
# file as-is (this is the known-working path on this cluster already).
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
POD_CIDR="${POD_CIDR:-}"

info() { echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"; }

wait_for_rollout() {
  local resource="$1" namespace="$2" timeout="${3:-180s}"
  echo "  ⏳ Waiting for ${resource} in ${namespace}..."
  kubectl rollout status "${resource}" -n "${namespace}" --timeout="${timeout}" \
    || echo "  ⚠️  Warning: ${resource} not ready — check it before continuing."
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Cilium (CNI)
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Cilium ${CILIUM_VERSION}…"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

cilium_set_args=()
if [[ -n "$CONTROL_PLANE_IP" ]]; then
  cilium_set_args+=(--set "k8sServiceHost=${CONTROL_PLANE_IP}" --set "k8sServicePort=6443")
fi
if [[ -n "$POD_CIDR" ]]; then
  cilium_set_args+=(--set "ipam.operator.clusterPoolIPv4PodCIDRList=${POD_CIDR}")
fi

helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --values "$REPO_ROOT/k8s/helm/cilium-values.yaml" \
  "${cilium_set_args[@]}" \
  --wait --timeout 5m

wait_for_rollout "daemonset/cilium" "kube-system" "180s"
wait_for_rollout "deployment/cilium-operator" "kube-system" "120s"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Argo CD
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Argo CD into namespace '${ARGOCD_NAMESPACE}'…"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

version_args=()
if [[ -n "$ARGOCD_CHART_VERSION" ]]; then
  version_args=(--version "$ARGOCD_CHART_VERSION")
fi

helm upgrade --install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  --values "$ARGOCD_DIR/bootstrap/argocd-values.yaml" \
  "${version_args[@]}" \
  --wait --timeout 5m

echo
info "Done. Initial Argo CD admin password:"
kubectl -n "$ARGOCD_NAMESPACE" get secret aargocd-initial-dmin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
echo
echo "==> UI: http://<any-node-public-or-private-ip>:30180  (user: admin)"
echo "==> Next (only if you haven't already filled in the chart versions in"
echo "    argocd/apps/*.yaml — see capture-versions.sh):"
echo
echo "      kubectl apply -f $ARGOCD_DIR/projects/"
echo "      kubectl apply -f $ARGOCD_DIR/root-app.yaml"
echo
echo "    From there Argo CD builds and manages everything else, including"
echo "    Cilium's ongoing lifecycle — deploy.sh is no longer needed."
