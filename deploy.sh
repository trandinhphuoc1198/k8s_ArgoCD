#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAMESPACE="${APP_NAMESPACE:-fastapi}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-observability}"
STORAGE_CLASS="${STORAGE_CLASS:-ebs-csi}"
APP_VALUES_FILE="${APP_VALUES_FILE:-}"
OTEL_OPERATOR_VERSION="${OTEL_OPERATOR_VERSION:-0.64.2}"

# ── Skip flags (set to "true" to skip a component) ───────────────────────────
SKIP_OTEL="${SKIP_OTEL:-false}"
SKIP_TEMPO="${SKIP_TEMPO:-false}"
TEMPO_VERSION="${TEMPO_VERSION:-1.9.0}"
SKIP_LOKI="${SKIP_LOKI:-false}"
LOKI_VERSION="${LOKI_VERSION:-6.12.0}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_command helm
require_command kubectl

# ─────────────────────────────────────────────────────────────────────────────
# Helm repos
# ─────────────────────────────────────────────────────────────────────────────
helm repo add metrics-server     https://kubernetes-sigs.github.io/metrics-server/         >/dev/null 2>&1 || true
helm repo add ingress-nginx      https://kubernetes.github.io/ingress-nginx                >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts      >/dev/null 2>&1 || true
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver      >/dev/null 2>&1 || true
helm repo add open-telemetry     https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add grafana             https://grafana.github.io/helm-charts                        >/dev/null 2>&1 || true
helm repo update

# ─────────────────────────────────────────────────────────────────────────────
# metrics-server
# ─────────────────────────────────────────────────────────────────────────────
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "$ROOT_DIR/k8s/helm/metrics-server-values.yaml"

kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

# ─────────────────────────────────────────────────────────────────────────────
# AWS EBS CSI driver
# ─────────────────────────────────────────────────────────────────────────────
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --values "$ROOT_DIR/k8s/helm/ebs-csi-values.yaml"

kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=120s
kubectl rollout status daemonset/ebs-csi-node        -n kube-system --timeout=120s

# ─────────────────────────────────────────────────────────────────────────────
# kube-prometheus-stack
# ─────────────────────────────────────────────────────────────────────────────
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --set fullnameOverride=monitoring \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/kube-prometheus-stack-values.yaml" \
  --set grafana.persistence.storageClassName="$STORAGE_CLASS" \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$STORAGE_CLASS"

kubectl rollout status deployment/monitoring-operator  -n "$MONITORING_NAMESPACE" --timeout=120s
kubectl rollout status deployment/kube-prometheus-stack-grafana   -n "$MONITORING_NAMESPACE" --timeout=120s

PROM_SS=$(kubectl get statefulset -n "$MONITORING_NAMESPACE" \
  -l "app.kubernetes.io/name=prometheus" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$PROM_SS" ]]; then
  kubectl rollout status statefulset/"$PROM_SS" -n "$MONITORING_NAMESPACE" --timeout=120s
else
  echo "Warning: No Prometheus StatefulSet found in namespace '$MONITORING_NAMESPACE' — skipping rollout check." >&2
fi

# ─────────────────────────────────────────────────────────────────────────────
# ingress-nginx
# ─────────────────────────────────────────────────────────────────────────────
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$INGRESS_NAMESPACE" \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/ingress-nginx-values.yaml"

kubectl rollout status deployment/ingress-nginx-controller -n "$INGRESS_NAMESPACE" --timeout=120s

# ─────────────────────────────────────────────────────────────────────────────
# OpenTelemetry Operator + Collector + Instrumentation CR
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_OTEL" != "true" ]]; then
  echo ""
  echo "🔭 Installing OpenTelemetry Operator v${OTEL_OPERATOR_VERSION}…"

  kubectl create namespace "$OTEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$OTEL_OPERATOR_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/otel-operator-values.yaml" \
    --wait \
    --timeout 5m

  # The admission webhook must be Ready before we apply the CRs —
  # otherwise the Instrumentation / OpenTelemetryCollector resources are rejected.
  echo "Waiting for OTel Operator webhook to become ready…"
  kubectl rollout status deployment/opentelemetry-operator \
    -n "$OTEL_NAMESPACE" --timeout=120s

  echo "🔭 Installing OTel Collectors + Instrumentation CR…"
  helm upgrade --install otel "$ROOT_DIR/charts/otel" \
    --namespace "$OTEL_NAMESPACE" \
    --values    "$ROOT_DIR/charts/otel/values.yaml" \
    --wait \
    --timeout 3m

  # Wait for both collectors to roll out
  OTEL_DS_NAME="otel-collector-ds-collector"
  OTEL_AGG_NAME="otel-collector-agg-collector"

  echo "Waiting for DaemonSet collector…"
  kubectl rollout status daemonset/"$OTEL_DS_NAME" -n "$OTEL_NAMESPACE" --timeout=120s 2>/dev/null \
    || echo "Warning: DaemonSet '$OTEL_DS_NAME' not found yet — it may still be provisioning."

  echo "Waiting for Aggregator Deployment collector…"
  kubectl rollout status deployment/"$OTEL_AGG_NAME" -n "$OTEL_NAMESPACE" --timeout=120s 2>/dev/null \
    || echo "Warning: Deployment '$OTEL_AGG_NAME' not found yet — it may still be provisioning."
else
  echo "⏭  SKIP_OTEL=true — skipping OpenTelemetry stack."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Grafana Tempo (distributed)
# Installed before fastapi-app so traces are captured from the first request.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_TEMPO" != "true" ]]; then
  echo ""
  echo "🟠 Installing Grafana Tempo distributed v${TEMPO_VERSION}…"

  helm upgrade --install tempo grafana/tempo-distributed \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$TEMPO_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/tempo-values.yaml" \
    --set       ingester.persistence.storageClass="$STORAGE_CLASS" \
    --wait \
    --timeout 5m

  echo "Waiting for Tempo distributor…"
  kubectl rollout status deployment/tempo-distributor -n "$OTEL_NAMESPACE" --timeout=120s 2>/dev/null \
    || echo "Warning: tempo-distributor not ready yet."

  echo "Waiting for Tempo query-frontend…"
  kubectl rollout status deployment/tempo-query-frontend -n "$OTEL_NAMESPACE" --timeout=120s 2>/dev/null \
    || echo "Warning: tempo-query-frontend not ready yet."

  echo "Waiting for Tempo ingester…"
  kubectl rollout status statefulset/tempo-ingester -n "$OTEL_NAMESPACE" --timeout=180s 2>/dev/null \
    || echo "Warning: tempo-ingester not ready yet."
else
  echo "⏭  SKIP_TEMPO=true — skipping Grafana Tempo."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Grafana Loki (distributed)
# Installed before fastapi-app so logs are captured from the first request.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_LOKI" != "true" ]]; then
  echo ""
  echo "🟡 Installing Grafana Loki distributed v${LOKI_VERSION}…"

  helm upgrade --install loki grafana/loki \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$LOKI_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/loki-values.yaml" \
    --wait \
    --set fullnameOverride=loki \
    --timeout 5m

else
  echo "⏭  SKIP_LOKI=true — skipping Grafana Loki."
fi

# ─────────────────────────────────────────────────────────────────────────────
# fastapi-app
# ─────────────────────────────────────────────────────────────────────────────
app_args=(
  upgrade --install fastapi-app "$ROOT_DIR/charts/fastapi-app"
  --namespace "$APP_NAMESPACE"
  --create-namespace
)

if [[ -n "$APP_VALUES_FILE" ]]; then
  app_args+=(--values "$APP_VALUES_FILE")
fi

helm "${app_args[@]}"
