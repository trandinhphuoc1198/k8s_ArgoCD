#!/usr/bin/env bash
# hooks/cert-manager-configs.sh
# Applies the cert-manager Issuer / Certificate / ClusterIssuer manifests.
# Called as a presync hook for the cert-manager-configs release.
# Mirrors ArgoCD Application 10-cert-manager-configs.yaml (path: platform/cert-manager).

set -euo pipefail

MANIFEST="$(dirname "$0")/../platform/cert-manager/cert-manager-config.yaml"

echo "→ Waiting for cert-manager webhook to be ready..."
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s

echo "→ Applying cert-manager configs from ${MANIFEST}"
kubectl apply -n cert-manager --server-side -f "${MANIFEST}"

echo "✓ cert-manager configs applied"