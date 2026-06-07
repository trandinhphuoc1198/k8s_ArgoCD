#!/usr/bin/env bash

set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-fastapi}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-observability}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_command helm
require_command kubectl

uninstall_release() {
  local release_name=$1
  local namespace=$2

  if helm status "$release_name" -n "$namespace" >/dev/null 2>&1; then
    echo "Uninstalling Helm release: $release_name in namespace: $namespace..."
    helm uninstall "$release_name" -n "$namespace" --wait
  else
    echo "Release $release_name not found in $namespace, skipping."
  fi
}

echo "🛑 Starting cluster teardown..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. Uninstall Workloads (Frees up the PVCs from active use)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "🚀 Removing FastAPI Application..."
uninstall_release fastapi-app "$APP_NAMESPACE"

echo ""
echo "🟡 Removing Grafana Loki..."
uninstall_release loki "$OTEL_NAMESPACE"

echo ""
echo "🟠 Removing Grafana Tempo..."
uninstall_release tempo "$OTEL_NAMESPACE"

echo ""
echo "🔭 Removing OpenTelemetry Stack..."
uninstall_release otel "$OTEL_NAMESPACE"
uninstall_release opentelemetry-operator "$OTEL_NAMESPACE"

echo ""
echo "📊 Removing Kube-Prometheus-Stack..."
uninstall_release kube-prometheus-stack "$MONITORING_NAMESPACE"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Delete PVCs (Must be done BEFORE removing the CSI driver)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "🧹 Checking and removing all PersistentVolumeClaims (PVCs)..."

for ns in "$APP_NAMESPACE" "$OTEL_NAMESPACE" "$MONITORING_NAMESPACE" "$INGRESS_NAMESPACE"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    PVC_COUNT=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)
    
    if [ "$PVC_COUNT" -gt 0 ]; then
      echo "Found ${PVC_COUNT} PVC(s) in namespace: ${ns}. Deleting..."
      kubectl delete pvc --all -n "$ns"
    else
      echo "No PVCs found in namespace: ${ns}."
    fi
  fi
done

echo "⏳ Waiting 15 seconds to allow AWS EBS CSI driver to process volume deletions..."
sleep 15

# ─────────────────────────────────────────────────────────────────────────────
# 3. Uninstall Base Infrastructure Components
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "🔀 Removing Ingress NGINX..."
uninstall_release ingress-nginx "$INGRESS_NAMESPACE"

echo ""
echo "💾 Removing AWS EBS CSI Driver..."
uninstall_release aws-ebs-csi-driver "kube-system"

echo ""
echo "📈 Removing Metrics Server..."
uninstall_release metrics-server "kube-system"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Clean up Namespaces
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "🗑️ Removing Namespaces..."

for ns in "$APP_NAMESPACE" "$OTEL_NAMESPACE" "$MONITORING_NAMESPACE" "$INGRESS_NAMESPACE"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "Deleting namespace: $ns..."
    kubectl delete namespace "$ns" --ignore-not-found
  else
    echo "Namespace $ns already removed."
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "✅ Teardown complete."
echo "Remaining PVCs across all namespaces (should be empty):"
kubectl get pvc -A
echo ""
echo "Remaining PVs (should be empty):"
kubectl get pv
echo ""