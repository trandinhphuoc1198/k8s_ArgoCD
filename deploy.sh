#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────
APP_NAMESPACE="${APP_NAMESPACE:-fastapi}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-observability}"
STORAGE_CLASS="${STORAGE_CLASS:-ebs-csi}"
APP_VALUES_FILE="${APP_VALUES_FILE:-}"

OTEL_OPERATOR_VERSION="${OTEL_OPERATOR_VERSION:-0.64.2}"
TEMPO_VERSION="${TEMPO_VERSION:-1.9.0}"
LOKI_VERSION="${LOKI_VERSION:-0.79.0}" # Note: Ensure this matches the community chart version you need

# ── Toggles ──────────────────────────────────────────────────────────────────
SKIP_OTEL="${SKIP_OTEL:-false}"
SKIP_TEMPO="${SKIP_TEMPO:-false}"
SKIP_LOKI="${SKIP_LOKI:-false}"

# ── Helper Functions ─────────────────────────────────────────────────────────
info() {
  echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "\033[1;31mError:\033[0m missing required command: $1" >&2
    exit 1
  fi
}

wait_for_rollout() {
  local resource="$1"
  local namespace="$2"
  local timeout="${3:-120s}"
  
  echo "  ⏳ Waiting for ${resource} in ${namespace}..."
  if ! kubectl rollout status "${resource}" -n "${namespace}" --timeout="${timeout}" 2>/dev/null; then
    echo "  ⚠️ Warning: ${resource} not ready or not found."
  fi
}

require_command helm
require_command kubectl

# ─────────────────────────────────────────────────────────────────────────────
# Helm Repositories
# ─────────────────────────────────────────────────────────────────────────────
info "Updating Helm repositories…"
helm repo add metrics-server     https://kubernetes-sigs.github.io/metrics-server/          >/dev/null 2>&1 || true
helm repo add ingress-nginx      https://kubernetes.github.io/ingress-nginx                 >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts       >/dev/null 2>&1 || true
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver       >/dev/null 2>&1 || true
helm repo add open-telemetry     https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add grafana            https://grafana.github.io/helm-charts                      >/dev/null 2>&1 || true
# Added the new Grafana Community repo for Loki Distributed
helm repo add grafana-community  https://grafana-community.github.io/helm-charts            >/dev/null 2>&1 || true
helm repo update

# ─────────────────────────────────────────────────────────────────────────────
# Metrics Server
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Metrics Server…"
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "$ROOT_DIR/k8s/helm/metrics-server-values.yaml"

wait_for_rollout "deployment/metrics-server" "kube-system"

# ─────────────────────────────────────────────────────────────────────────────
# AWS EBS CSI Driver
# ─────────────────────────────────────────────────────────────────────────────
info "Installing AWS EBS CSI Driver…"
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --values "$ROOT_DIR/k8s/helm/ebs-csi-values.yaml"

wait_for_rollout "deployment/ebs-csi-controller" "kube-system"
wait_for_rollout "daemonset/ebs-csi-node" "kube-system"

# ─────────────────────────────────────────────────────────────────────────────
# Kube Prometheus Stack
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Kube-Prometheus-Stack…"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --set fullnameOverride=monitoring \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/kube-prometheus-stack-values.yaml" \
  --set grafana.persistence.storageClassName="$STORAGE_CLASS" \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$STORAGE_CLASS"

wait_for_rollout "deployment/monitoring-operator" "$MONITORING_NAMESPACE"
wait_for_rollout "deployment/kube-prometheus-stack-grafana" "$MONITORING_NAMESPACE"

PROM_SS=$(kubectl get statefulset -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$PROM_SS" ]]; then
  wait_for_rollout "statefulset/${PROM_SS}" "$MONITORING_NAMESPACE"
else
  echo "  ⚠️ Warning: No Prometheus StatefulSet found in namespace '$MONITORING_NAMESPACE' — skipping rollout check." >&2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Ingress NGINX
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Ingress NGINX…"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$INGRESS_NAMESPACE" \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/ingress-nginx-values.yaml"

wait_for_rollout "deployment/ingress-nginx-controller" "$INGRESS_NAMESPACE"

# ─────────────────────────────────────────────────────────────────────────────
# OpenTelemetry Operator + Collector + Instrumentation
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_OTEL" != "true" ]]; then
  info "Installing OpenTelemetry Operator v${OTEL_OPERATOR_VERSION}…"
  kubectl create namespace "$OTEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$OTEL_OPERATOR_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/otel-operator-values.yaml" \
    --wait \
    --timeout 5m

  wait_for_rollout "deployment/opentelemetry-operator" "$OTEL_NAMESPACE"

  info "Installing OTel Collectors + Instrumentation CR…"
  helm upgrade --install otel "$ROOT_DIR/charts/otel" \
    --namespace "$OTEL_NAMESPACE" \
    --values    "$ROOT_DIR/charts/otel/values.yaml" \
    --wait \
    --timeout 3m

  wait_for_rollout "daemonset/otel-collector-ds-collector" "$OTEL_NAMESPACE"
  wait_for_rollout "deployment/otel-collector-agg-collector" "$OTEL_NAMESPACE"
else
  info "⏭  SKIP_OTEL=true — skipping OpenTelemetry stack."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Grafana Tempo (Distributed)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_TEMPO" != "true" ]]; then
  info "Installing Grafana Tempo Distributed v${TEMPO_VERSION}…"
  helm upgrade --install tempo grafana/tempo-distributed \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$TEMPO_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/tempo-values.yaml" \
    --set       ingester.persistence.storageClass="$STORAGE_CLASS" \
    --wait \
    --timeout 5m

  wait_for_rollout "deployment/tempo-distributor" "$OTEL_NAMESPACE"
  wait_for_rollout "deployment/tempo-query-frontend" "$OTEL_NAMESPACE"
  wait_for_rollout "statefulset/tempo-ingester" "$OTEL_NAMESPACE" "180s"
else
  info "⏭  SKIP_TEMPO=true — skipping Grafana Tempo."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Grafana Loki (Distributed via Community Chart)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_LOKI" != "true" ]]; then
  info "Installing Grafana Loki Distributed v${LOKI_VERSION}…"
  
  # Note the chart reference is updated to grafana-community/loki-distributed
  helm upgrade --install loki grafana-community/loki-distributed \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$LOKI_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/loki-values.yaml" \
    --wait \
    --timeout 5m

  # Added specific rollout checks for the distributed Loki microservices
  wait_for_rollout "deployment/loki-loki-distributed-gateway" "$OTEL_NAMESPACE"
  wait_for_rollout "deployment/loki-loki-distributed-distributor" "$OTEL_NAMESPACE"
  wait_for_rollout "statefulset/loki-loki-distributed-ingester" "$OTEL_NAMESPACE" "180s"
else
  info "⏭  SKIP_LOKI=true — skipping Grafana Loki."
fi

# ─────────────────────────────────────────────────────────────────────────────
# FastAPI App
# ─────────────────────────────────────────────────────────────────────────────
info "Installing FastAPI Application…"
app_args=(
  upgrade --install fastapi-app "$ROOT_DIR/charts/fastapi-app"
  --namespace "$APP_NAMESPACE"
  --create-namespace
)

if [[ -n "$APP_VALUES_FILE" ]]; then
  app_args+=(--values "$APP_VALUES_FILE")
fi

helm "${app_args[@]}"

info "✅ Deployment script completed successfully."