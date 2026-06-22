#!/usr/bin/env bash
#
# tear-down.sh (Automated Cluster Purge & Resource Destruction Script)
# Location: Root folder (C:\...)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# Terminal Formatting Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

info() { echo -e "\n${BLUE}==>${NC} \033[1m$1\033[0m"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo -e "${RED}==================================================${NC}"
echo -e "${RED}    Starting Automated Cluster Resource Purge     ${NC}"
echo -e "${RED}==================================================${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Purge PVCs and PVs FIRST (While Storage Drivers are Active)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 1/6: Purging all PVCs and PVs before stripping storage drivers..."
namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
for ns in $namespaces; do
    if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease)$ ]]; then
        continue
    fi
    
    pvc_list=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
    if [[ -n "$pvc_list" ]]; then
        echo "Found PVCs in namespace [$ns]. Initializing deletion..."
        # Strip finalizers to prevent stuck cloud storage attachments
        for pvc in $pvc_list; do
            kubectl patch pvc "$pvc" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
        kubectl delete pvc --all -n "$ns" --timeout=45s || true
    fi
done

echo "Purging lingering Persistent Volumes (PVs)..."
pv_list=$(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
for pv in $pv_list; do
    kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
kubectl delete pv --all --timeout=30s || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Remove Root App and Patch Finalizers
# ─────────────────────────────────────────────────────────────────────────────
info "Step 2/6: Removing ArgoCD Root App..."
if kubectl get application root-app -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    kubectl delete application root-app -n "$ARGOCD_NAMESPACE" --timeout=45s || {
        warn "Root app deletion timed out. Force-clearing finalizers..."
        kubectl patch application root-app -n "$ARGOCD_NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge || true
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Delete All Downstream ArgoCD Applications & Projects
# ─────────────────────────────────────────────────────────────────────────────
info "Step 3/6: Purging managed applications and resources..."
apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
for app in $apps; do
    echo "Deleting application: $app"
    kubectl patch application "$app" -n "$ARGOCD_NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete application "$app" -n "$ARGOCD_NAMESPACE" --cascade=foreground --timeout=20s 2>/dev/null || true
done

if [ -d "$REPO_ROOT/argocd/projects" ]; then
    echo "Deleting AppProjects..."
    kubectl delete -f "$REPO_ROOT/argocd/projects/" --ignore-not-found=true --timeout=20s || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Purge Bootstrap Helm Releases (ArgoCD, Autoscaler, Cilium)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 4/6: Uninstalling Base Helm Releases..."
echo "Uninstalling Argo CD..."
helm uninstall argocd --namespace "$ARGOCD_NAMESPACE" 2>/dev/null || true

echo "Uninstalling Cluster Autoscaler..."
helm uninstall cluster-autoscaler --namespace kube-system 2>/dev/null || true

echo "Uninstalling Cilium..."
helm uninstall cilium --namespace kube-system 2>/dev/null || true

echo "Uninstalling Prometheus Operator CRDs..."
helm uninstall prometheus-operator-crds --namespace monitoring 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Clean Up Target Namespaces
# ─────────────────────────────────────────────────────────────────────────────
info "Step 5/6: Terminating operational Namespaces..."
for ns in "$ARGOCD_NAMESPACE" "monitoring"; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Deleting namespace: $ns"
        kubectl delete namespace "$ns" --timeout=45s || {
            warn "Namespace $ns stuck. Forcing cluster finalizer release..."
            kubectl get namespace "$ns" -o json | tr -d "\n" | sed 's/"spec":\s*{\s*"finalizers":\s*\[[^]]*\]\s*}/"spec":{"finalizers":[]}/g' | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - || true
        }
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Verification Output
# ─────────────────────────────────────────────────────────────────────────────
info "Step 6/6: Verifying cleanup state..."
kubectl get pvc,pv,apps,appprojects --all-namespaces 2>/dev/null || echo "No tracked GitOps assets remain."

echo -e "\n${RED}==================================================${NC}"
echo -e "${RED}       Teardown Completed Successfully!           ${NC}"
echo -e "${RED}==================================================${NC}"