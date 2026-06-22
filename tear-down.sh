#!/usr/bin/env bash
#
# tear-down.sh (Aggressive Multi-Application Cluster Purge)
# Location: Root folder (C:\...)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

info() { echo -e "\n${BLUE}==>${NC} \033[1m$1\033[0m"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo -e "${RED}==================================================${NC}"
echo -e "${RED}    Executing Aggressive Global Cluster Purge    ${NC}"
echo -e "${RED}==================================================${NC}"

# Get all non-system namespaces to target
TARGET_NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -vE '^(kube-system|kube-public|kube-node-lease)$' || true)

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Strip Application Management Frameworks First
# ─────────────────────────────────────────────────────────────────────────────
info "Step 1/5: Clearing ArgoCD GitOps tracking apps..."
if kubectl get application root-app -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    kubectl patch application root-app -n "$ARGOCD_NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete application root-app -n "$ARGOCD_NAMESPACE" --timeout=10s || true
fi

apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
for app in $apps; do
    kubectl patch application "$app" -n "$ARGOCD_NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete application "$app" -n "$ARGOCD_NAMESPACE" --timeout=10s || true
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Aggressive Workload Nuke (Deployments, StatefulSets, DaemonSets, Pods)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 2/5: Hunting and breaking all running application workloads..."
for ns in $TARGET_NAMESPACES; do
    echo "Processing namespace: [$ns]"
    
    # Target all controller types that keep bringing pods back to life
    for resource in deployments statefulsets daemonsets replicasets jobs cronjobs pods; do
        items=$(kubectl get "$resource" -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
        if [[ -n "$items" ]]; then
            echo "  -> Found $resource elements. Stripping finalizers and forcing deletion..."
            for item in $items; do
                kubectl patch "$resource" "$item" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            done
            # Background the delete commands so they execute simultaneously across apps
            kubectl delete "$resource" --all -n "$ns" --force --grace-period=0 --timeout=15s >/dev/null 2>&1 &
        fi
    done
done
wait # Wait for background force deletions to clear

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Purge PVCs and PVs (While cloud storage controllers are still online)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 3/5: Erasing persistent storage configurations..."
for ns in $TARGET_NAMESPACES; do
    pvc_list=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
    if [[ -n "$pvc_list" ]]; then
        for pvc in $pvc_list; do
            kubectl patch pvc "$pvc" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
        kubectl delete pvc --all -n "$ns" --force --grace-period=0 --timeout=20s >/dev/null 2>&1 &
    fi
done
wait

pv_list=$(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
for pv in $pv_list; do
    kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
kubectl delete pv --all --force --grace-period=0 --timeout=20s >/dev/null 2>&1 || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Uninstall Helm Releases (Infrastructure Drivers)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 4/5: Disabling core system engine Helm deployments..."
helm uninstall argocd --namespace "$ARGOCD_NAMESPACE" 2>/dev/null || true
helm uninstall cluster-autoscaler --namespace kube-system 2>/dev/null || true
helm uninstall cilium --namespace kube-system 2>/dev/null || true
helm uninstall prometheus-operator-crds --namespace monitoring 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Wipe Out Residual Namespaces
# ─────────────────────────────────────────────────────────────────────────────
info "Step 5/5: Sweeping remaining namespaces..."
for ns in $TARGET_NAMESPACES; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        kubectl delete namespace "$ns" --timeout=20s || {
            # Direct raw etcd patch override if the namespace stays stuck
            kubectl get namespace "$ns" -o json | tr -d "\n" | sed 's/"spec":\s*{\s*"finalizers":\s*\[[^]]*\]\s*}/"spec":{"finalizers":[]}/g' | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - || true
        }
    fi
done

echo -e "\n${RED}==================================================${NC}"
echo -e "${RED}   All discovered app pods and drivers purged!    ${NC}"
echo -e "${RED}==================================================${NC}"