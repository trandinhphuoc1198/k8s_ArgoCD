#!/usr/bin/env bash
# hooks/grafana-dashboards.sh
# Applies the Grafana dashboard ConfigMaps from platform/grafana-dashboards/.
# Called by helmfile as a presync hook for the grafana-dashboards release.
# Mirrors what ArgoCD Application 30-grafana-dashboards.yaml does with
# `directory.recurse: false` and `exclude: "*.md"`.

set -euo pipefail

DASHBOARDS_DIR="$(dirname "$0")/../platform/grafana-dashboards"

echo "→ Applying Grafana dashboard ConfigMaps from ${DASHBOARDS_DIR}"

kubectl apply -n monitoring \
  --server-side \
  -f <(find "${DASHBOARDS_DIR}" -maxdepth 1 -name "*.yaml" | sort | xargs cat)

echo "✓ Grafana dashboards applied"