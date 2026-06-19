#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL additions for deploy.sh
# Insert these blocks into your existing deploy.sh at the appropriate position:
#   1. CNPG operator BEFORE your app charts
#   2. Namespace + postgresql chart AFTER operator is ready
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Add the CloudNativePG Helm repo ───────────────────────────────────────
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

# ── 2. Install the CNPG operator (cluster-scoped, its own namespace) ─────────
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --values k8s/helm/cnpg-values.yaml \
  --wait \
  --timeout 5m

echo "✅ CloudNativePG operator ready"

#    ⚠️  Set a real password here — never commit plain-text passwords.
#    Use: --set secret.password=$(echo -n 'yourpassword' | base64)
#    Or store the secret separately and skip secret.yaml in the chart.
helm upgrade --install postgresql "$ROOT_DIR/charts/postgresql" \
  --namespace db \
  --create-namespace \
  --wait \
  --timeout 5m

