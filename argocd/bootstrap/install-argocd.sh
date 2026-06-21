#!/usr/bin/env bash
#
# argocd/bootstrap/install-argocd.sh
#
# Installs Argo CD itself onto the cluster. Run this once, by hand, with
# kubectl/helm pointed at the target cluster. Everything AFTER this point
# (all infra + the app) is managed by Argo CD via the root Application.
#
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}"   # leave empty for latest; pin once you've verified it

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Adding argo-helm repo"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update

echo "==> Installing Argo CD into namespace '${ARGOCD_NAMESPACE}'"
version_args=()
if [[ -n "$ARGOCD_CHART_VERSION" ]]; then
  version_args=(--version "$ARGOCD_CHART_VERSION")
fi

helm upgrade --install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  --values "$ROOT_DIR/bootstrap/argocd-values.yaml" \
  "${version_args[@]}" \
  --wait --timeout 5m

echo
echo "==> Argo CD installed. Initial admin password:"
kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
echo
echo "==> UI: http://<any-node-public-or-private-ip>:30180  (user: admin)"
echo "==> Next: fill in chart versions (see capture-versions.sh), then:"
echo "      kubectl apply -f $ROOT_DIR/root-app.yaml"
