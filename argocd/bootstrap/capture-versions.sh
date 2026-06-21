#!/usr/bin/env bash
#
# argocd/bootstrap/capture-versions.sh
#
# WHY THIS MATTERS:
# Several charts in deploy.sh are installed WITHOUT a pinned --version, which
# means whatever was "latest" on the day someone ran deploy.sh is what's
# actually running on the cluster right now. The Argo CD Application
# manifests in argocd/apps/ need an explicit targetRevision for every Helm
# chart — there's no "use latest" option for a GitOps source of truth.
#
# If you guess wrong (e.g. pin a newer version than what's deployed), the
# very first sync — which is auto-sync + self-heal per your setup — will
# immediately upgrade that component in place. For things like
# kube-prometheus-stack or ingress-nginx, an unplanned major-version jump
# can break the cluster on adoption day.
#
# Run this against your LIVE cluster first, then copy the versions into the
# `targetRevision: "REPLACE_ME"` fields in argocd/apps/*.yaml before you
# apply root-app.yaml.
#
set -euo pipefail

echo "Currently installed Helm releases (chart + version):"
echo
helm list -A -o table | awk '{printf "%-30s %-15s %-40s\n", $1, $2, $9}'

echo
echo "Raw, for scripting:"
helm list -A -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data:
    print(f"{r[\"name\"]:<30} ns={r[\"namespace\"]:<18} chart={r[\"chart\"]}")
'

cat <<'EOF'

Map releases -> argocd/apps/*.yaml targetRevision:
  prometheus-operator-crds  -> 00-prometheus-operator-crds.yaml
  aws-ebs-csi-driver        -> 10-aws-ebs-csi-driver.yaml
  ingress-nginx             -> 10-ingress-nginx.yaml
  keda                      -> 10-keda.yaml
  cnpg                      -> 10-cnpg-operator.yaml
  kube-prometheus-stack     -> 20-kube-prometheus-stack.yaml

(cilium, cluster-autoscaler, opentelemetry-operator, tempo, loki are already
pinned to match deploy.sh's explicit --version flags — double check those
still match what's actually running with `helm list -A` above, but they
shouldn't need editing.)
EOF
