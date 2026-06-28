#!/usr/bin/env bash
#
# init.sh (All-in-One Bootstrap Script)
# Location: Root folder
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration & Context Resolution
# ─────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_DIR="$REPO_ROOT/argocd"
PLATFORM_DIR="$REPO_ROOT/platform" # Added context for platform directory

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}" 

CILIUM_VERSION="${CILIUM_VERSION:-1.16.0}"          
AUTO_SCALER_VERSION="${AUTO_SCALER_VERSION:-9.37.0}" 

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-10.0.1.10}"
POD_CIDR="${POD_CIDR:-}"

# Terminal Formatting Colors
GREEN='\033[0;32m'
BLUE='\033[1;34m'
NC='\033[0m'

info() { echo -e "\n${BLUE}==>${NC} \033[1m$1\033[0m"; }

wait_for_rollout() {
  local resource="$1" namespace="$2" timeout="${3:-180s}"
  echo "  ⏳ Waiting for ${resource} in ${namespace}..."
  kubectl rollout status "${resource}" -n "${namespace}" --timeout="${timeout}" \
    || echo "  ⚠️  Warning: ${resource} not ready — check it before continuing."
}

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}    Starting GitOps Cluster Bootstrap Engine     ${NC}"
echo -e "${BLUE}==================================================${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Initialize Repositories & Install Core Infrastructure (Pre-ArgoCD)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 1/4: Syncing Helm Repositories & Pre-requisites..."
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

# 1.1 Prometheus Operator CRDs
info "Installing Prometheus Operator CRDs…"
helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
  --namespace monitoring \
  --create-namespace \
  --wait

# 1.2 Cilium CNI
info "Installing Cilium ${CILIUM_VERSION}…"
cilium_set_args=()
if [[ -n "$CONTROL_PLANE_IP" ]]; then
  cilium_set_args+=(--set "k8sServiceHost=${CONTROL_PLANE_IP}" --set "k8sServicePort=6443")
fi
if [[ -n "$POD_CIDR" ]]; then
  cilium_set_args+=(--set "ipam.operator.clusterPoolIPv4PodCIDRList=${POD_CIDR}")
fi

# UPDATED: Pointed to the new platform/upstream-values location
helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --values "$PLATFORM_DIR/upstream-values/cilium-values.yaml" \
  "${cilium_set_args[@]}" \
  --wait --timeout 5m

wait_for_rollout "daemonset/cilium" "kube-system" "180s"
wait_for_rollout "deployment/cilium-operator" "kube-system" "120s"

# 1.3 Cluster Autoscaler
info "Installing Cluster Autoscaler ${AUTO_SCALER_VERSION}…"
# UPDATED: Pointed to the new platform/upstream-values location
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version "$AUTO_SCALER_VERSION" \
  --values "$PLATFORM_DIR/upstream-values/auto-scaler-values.yaml" \
  --wait --timeout 3m

wait_for_rollout "deployment/cluster-autoscaler" "kube-system" "120s"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Install Argo CD Core
# ─────────────────────────────────────────────────────────────────────────────
info "Step 2/4: Installing Argo CD into namespace '${ARGOCD_NAMESPACE}'…"
version_args=()
if [[ -n "$ARGOCD_CHART_VERSION" ]]; then
  version_args=(--version "$ARGOCD_CHART_VERSION")
fi

helm upgrade --install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  --values "$ARGOCD_DIR/bootstrap/argocd-values.yaml" \
  "${version_args[@]}" \
  --wait --timeout 5m

wait_for_rollout "deployment/argocd-server" "$ARGOCD_NAMESPACE" "180s"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Register AppProjects
# ─────────────────────────────────────────────────────────────────────────────
info "Step 3/4: Registering AppProjects..."
if [ -d "$ARGOCD_DIR/projects" ]; then
    kubectl apply -f "$ARGOCD_DIR/projects/"
else
    echo "⚠️ Warning: '$ARGOCD_DIR/projects' directory not found. Skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Apply Root Application (App-of-Apps Takeover)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 4/4: Deploying Root Application..."
if [ -f "$ARGOCD_DIR/root-app.yaml" ]; then
    kubectl apply -f "$ARGOCD_DIR/root-app.yaml"
    echo -e "${GREEN}✓ Root App successfully applied!${NC}"
else
    echo "❌ Error: '$ARGOCD_DIR/root-app.yaml' not found. Cannot trigger cluster sync."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done & Password Recovery Output
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}             Bootstrap Complete!                  ${NC}"
echo -e "${GREEN}  ArgoCD is now managing the entire cluster.     ${NC}"
echo -e "${GREEN}==================================================${NC}"

info "Initial Argo CD admin password:"
kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | { base64 -d 2>/dev/null || base64 --decode; }
echo
echo
echo "==> UI Access Point: http://<any-node-ip>:30180  (User: admin)"
echo "==> ArgoCD is running target matching checks against your Git configs..."