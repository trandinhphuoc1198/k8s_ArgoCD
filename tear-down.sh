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
# Step 3: Purge PVCs and PVs (Letting CSI Drivers Delete AWS Infrastructure)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 3/5: Erasing persistent storage configurations..."

# 1. Issue a normal delete first so the AWS EBS CSI driver receives the API call
for ns in $TARGET_NAMESPACES; do
    if kubectl get pvc -n "$ns" >/dev/null 2>&1; then
        echo "  -> Requesting graceful deletion of PVCs in [$ns]..."
        kubectl delete pvc --all -n "$ns" --timeout=30s >/dev/null 2>&1 &
    fi
done
wait

# 2. Give the cloud provider 10 seconds to process the under-the-hood AWS API calls
echo "Waiting 10 seconds for cloud storage providers to release infrastructure..."
sleep 10

# 3. ONLY strip finalizers if resources are obstinately stuck in 'Terminating'
for ns in $TARGET_NAMESPACES; do
    stuck_pvcs=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
    if [[ -n "$stuck_pvcs" ]]; then
        warn "PVCs stuck in [$ns]. Forcing finalizer stripping (May cause AWS orphans!)."
        for pvc in $stuck_pvcs; do
            kubectl patch pvc "$pvc" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
        kubectl delete pvc --all -n "$ns" --force --grace-period=0 --timeout=5s >/dev/null 2>&1 || true
    fi
done

# 4. Gracefully handle PVs
if kubectl get pv >/dev/null 2>&1; then
    kubectl delete pv --all --timeout=15s >/dev/null 2>&1 || true
    
    # Ultimate fallback for PV metadata
    stuck_pvs=$(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || ""
    for pv in $stuck_pvs; do
        kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    kubectl delete pv --all --force --grace-period=0 --timeout=5s >/dev/null 2>&1 || true
fi
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