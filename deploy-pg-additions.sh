#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL additions for deploy.sh
# Insert these blocks into your existing deploy.sh at the appropriate position:
#   1. CNPG operator BEFORE your app charts
#   2. Namespace + postgresql chart AFTER operator is ready
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

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

# ── 3. Create the db namespace ───────────────────────────────────────────────
kubectl create namespace db --dry-run=client -o yaml | kubectl apply -f -

# ── 4. Deploy the PostgreSQL chart ───────────────────────────────────────────
#    ⚠️  Set a real password here — never commit plain-text passwords.
#    Use: --set secret.password=$(echo -n 'yourpassword' | base64)
#    Or store the secret separately and skip secret.yaml in the chart.
helm upgrade --install postgresql charts/postgresql \
  --namespace db \
  --set secret.password="$(echo -n "${PG_PASSWORD:?PG_PASSWORD env var required}" | base64)" \
  --wait \
  --timeout 5m

echo "✅ PostgreSQL cluster ready"

# ── 5. Verify ────────────────────────────────────────────────────────────────
kubectl get cluster -n db
kubectl get pods   -n db


# ─────────────────────────────────────────────────────────────────────────────
# tear-down.sh additions
# ─────────────────────────────────────────────────────────────────────────────

# ── Remove PostgreSQL chart (PVCs kept by default — data safe) ───────────────
helm uninstall postgresql --namespace db || true

# ── To also DELETE the data PVCs (DESTRUCTIVE): ──────────────────────────────
# kubectl delete pvc -n db --all

# ── Remove CNPG operator ─────────────────────────────────────────────────────
helm uninstall cnpg --namespace cnpg-system || true
kubectl delete namespace db          || true
kubectl delete namespace cnpg-system || true
