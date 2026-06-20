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
TEMPO_VERSION="${TEMPO_VERSION:-1.60.0}"
LOKI_VERSION="${LOKI_VERSION:-12.0.0}" 
AUTO_SCALER_VERSION="${AUTO_SCALER_VERSION:-9.37.0}" 

# ── Toggles ──────────────────────────────────────────────────────────────────
SKIP_OTEL="${SKIP_OTEL:-false}"
SKIP_TEMPO="${SKIP_TEMPO:-false}"
SKIP_LOKI="${SKIP_LOKI:-false}"

# ── Helper Functions ─────────────────────────────────────────────────────────
info() {
  echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"
}

# NEW: Wrapper function to print the command before executing it
run_cmd() {
  echo -e "  \033[90m$ $*\033[0m" # Prints the command in dim gray
  "$@"
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
  # Use run_cmd inside the rollout check as well
  if ! run_cmd kubectl rollout status "${resource}" -n "${namespace}" --timeout="${timeout}"; then
    echo "  ⚠️ Warning: ${resource} not ready or not found."
  fi
}

require_command helm
require_command kubectl

# ─────────────────────────────────────────────────────────────────────────────
# Helm Repositories
# ─────────────────────────────────────────────────────────────────────────────
info "Updating Helm repositories…"

run_cmd helm repo add cilium             https://helm.cilium.io/                                   >/dev/null 2>&1 || true
run_cmd helm repo add autoscaler     https://kubernetes.github.io/autoscaler          >/dev/null 2>&1 || true
run_cmd helm repo add metrics-server     https://kubernetes-sigs.github.io/metrics-server/          >/dev/null 2>&1 || true
run_cmd helm repo add ingress-nginx      https://kubernetes.github.io/ingress-nginx                 >/dev/null 2>&1 || true
run_cmd helm repo add prometheus-community https://prometheus-community.github.io/helm-charts       >/dev/null 2>&1 || true
run_cmd helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver       >/dev/null 2>&1 || true
run_cmd helm repo add open-telemetry     https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
run_cmd helm repo add grafana            https://grafana.github.io/helm-charts                      >/dev/null 2>&1 || true
run_cmd helm repo add grafana-community  https://grafana-community.github.io/helm-charts            >/dev/null 2>&1 || true
run_cmd helm repo add kedacore           https://kedacore.github.io/charts                            >/dev/null 2>&1 || true
run_cmd helm repo add cnpg https://cloudnative-pg.github.io/charts
run_cmd helm repo update

# ─────────────────────────────────────────────────────────────────────────────
# Cilium (upgrade only — already installed by cloud-init at node boot)
# Idempotent: only applies values changes (Hubble metrics, ServiceMonitors,
# UI ingress). Does NOT restart the CNI data plane unless values changed.
# ─────────────────────────────────────────────────────────────────────────────
info "Upgrading Cilium…"

helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
  -n monitoring --create-namespace

# CONTROL_PLANE_IP="${CONTROL_PLANE_IP:?Set CONTROL_PLANE_IP to the private IP of your control-plane node}"
# POD_CIDR="${POD_CIDR:-192.168.0.0/16}"

run_cmd helm upgrade --install cilium cilium/cilium \
  --version   "1.16.0" \
  --namespace kube-system \
  --values    "$ROOT_DIR/k8s/helm/cilium-values.yaml" \
  --wait \
  --timeout 5m 
  # --set ipam.operator.clusterPoolIPv4PodCIDRList="$POD_CIDR" \
  # --set k8sServiceHost="$CONTROL_PLANE_IP" \
  # --set k8sServicePort="6443" 

wait_for_rollout "daemonset/cilium"           "kube-system" "180s"
wait_for_rollout "deployment/cilium-operator" "kube-system" "120s"

# ─────────────────────────────────────────────────────────────────────────────
# Auto scaler
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Auto scaler…"
run_cmd helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version "$AUTO_SCALER_VERSION" \
  --values "$ROOT_DIR/k8s/helm/auto-scaler-values.yaml"

# ─────────────────────────────────────────────────────────────────────────────
# Metrics Server
# ─────────────────────────────────────────────────────────────────────────────
# info "Installing Metrics Server…"
# run_cmd helm upgrade --install metrics-server metrics-server/metrics-server \
#   --namespace kube-system \
#   --values "$ROOT_DIR/k8s/helm/metrics-server-values.yaml"

# wait_for_rollout "deployment/metrics-server" "kube-system"

# ─────────────────────────────────────────────────────────────────────────────
# AWS EBS CSI Driver
# ─────────────────────────────────────────────────────────────────────────────
info "Installing AWS EBS CSI Driver…"
run_cmd helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --values "$ROOT_DIR/k8s/helm/ebs-csi-values.yaml"

wait_for_rollout "deployment/ebs-csi-controller" "kube-system"
wait_for_rollout "daemonset/ebs-csi-node" "kube-system"

# ─────────────────────────────────────────────────────────────────────────────
# Kube Prometheus Stack
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Kube-Prometheus-Stack…"
run_cmd helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --set fullnameOverride=monitoring \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/kube-prometheus-stack-values.yaml" \
  --set grafana.persistence.storageClassName="$STORAGE_CLASS" \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$STORAGE_CLASS"

wait_for_rollout "deployment/monitoring-operator" "$MONITORING_NAMESPACE"
wait_for_rollout "deployment/kube-prometheus-stack-grafana" "$MONITORING_NAMESPACE"

echo -e "  \033[90m$ kubectl get statefulset -n \"$MONITORING_NAMESPACE\" ...\033[0m"
PROM_SS=$(kubectl get statefulset -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$PROM_SS" ]]; then
  wait_for_rollout "statefulset/${PROM_SS}" "$MONITORING_NAMESPACE"
else
  echo "  ⚠️ Warning: No Prometheus StatefulSet found in namespace '$MONITORING_NAMESPACE' — skipping rollout check." >&2
fi

# Apply Hubble dashboard — auto-imported by the Grafana ConfigMap sidecar
info "Applying Hubble Grafana dashboard…"
run_cmd kubectl apply -f "$ROOT_DIR/k8s/helm/hubble-grafana-dashboard.yaml"

# ─────────────────────────────────────────────────────────────────────────────
# Ingress NGINX
# ─────────────────────────────────────────────────────────────────────────────
info "Installing Ingress NGINX…"
run_cmd helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$INGRESS_NAMESPACE" \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/ingress-nginx-values.yaml"

wait_for_rollout "deployment/ingress-nginx-controller" "$INGRESS_NAMESPACE"

# ─────────────────────────────────────────────────────────────────────────────
# OpenTelemetry Operator + Collector + Instrumentation
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_OTEL" != "true" ]]; then
  info "Installing OpenTelemetry Operator v${OTEL_OPERATOR_VERSION}…"
  
  echo -e "  \033[90m$ kubectl create namespace $OTEL_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -\033[0m"
  kubectl create namespace "$OTEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  run_cmd helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$OTEL_OPERATOR_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/otel-operator-values.yaml" \
    --wait \
    --timeout 5m

  wait_for_rollout "deployment/opentelemetry-operator" "$OTEL_NAMESPACE"

  info "Installing OTel Collectors + Instrumentation CR…"
  run_cmd helm upgrade --install otel "$ROOT_DIR/charts/otel" \
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
  run_cmd helm upgrade --install tempo grafana/tempo-distributed \
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
  
  run_cmd helm upgrade --install loki grafana-community/loki \
    --namespace "$OTEL_NAMESPACE" \
    --version   "$LOKI_VERSION" \
    --values    "$ROOT_DIR/k8s/helm/loki-values.yaml" \
    --wait \
    --timeout 5m

  wait_for_rollout "deployment/loki-gateway" "$OTEL_NAMESPACE"
  wait_for_rollout "statefulset/loki" "$OTEL_NAMESPACE"
  wait_for_rollout "statefulset/loki-loki-distributed-ingester" "$OTEL_NAMESPACE" "180s"
else
  info "⏭  SKIP_LOKI=true — skipping Grafana Loki."
fi


# ─────────────────────────────────────────────────────────────────────────────
# KEDA
# ─────────────────────────────────────────────────────────────────────────────
info "Installing KEDA…"
run_cmd helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --values "$ROOT_DIR/k8s/helm/keda-values.yaml" \
  --wait

wait_for_rollout "deployment/keda-operator"               "keda"
wait_for_rollout "deployment/keda-operator-metrics-apiserver" "keda"

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

# Expand the array explicitly so it prints properly with run_cmd
run_cmd helm "${app_args[@]}"

# Create DB
run_cmd helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --values k8s/helm/cnpg-values.yaml \
  --wait \
  --timeout 5m

info "✅ CloudNativePG operator ready"

run_cmd helm upgrade --install postgresql "$ROOT_DIR/charts/postgresql" \
  --namespace db \
  --create-namespace \
  --wait \
  --timeout 5m


info "✅ Deployment dashboard."

run_cmd kubectl apply -f "$ROOT_DIR/grafana-dashboards/"

info "✅ Deployment script completed successfully."