#!/usr/bin/env bash
#
# argocd/bootstrap/teardown.sh
#
# Safely tears down the entire cluster stack — Argo CD managed resources,
# all Helm releases, and critically, all EBS volumes spawned by PVCs —
# without leaving orphaned AWS resources behind.
#
# ─── WHY ORDER MATTERS ───────────────────────────────────────────────────────
#
#  The StorageClass uses reclaimPolicy: Delete. That means the EBS CSI driver
#  automatically deletes the underlying EBS volume when a PVC is deleted.
#  HOWEVER: if the CSI driver is uninstalled before the PVCs are deleted, the
#  EBS volumes become permanently orphaned — Kubernetes removes the PV object
#  but AWS never receives the DeleteVolume call. They keep accruing charges
#  indefinitely and show up in your AWS bill long after the cluster is gone.
#
#  The CNPG operator puts a finalizer (cnpg.io/cluster) on the Cluster CR.
#  Deleting the Cluster CR triggers the operator to clean up its own PVCs —
#  but only if the operator pod is still running. So the Cluster CR must be
#  deleted (and its PVCs confirmed gone) before the cnpg-operator release is
#  uninstalled.
#
#  Argo CD has auto-sync + self-heal enabled. If you start deleting Helm
#  releases by hand without disabling Argo CD first, it will immediately
#  re-create whatever you just removed. So Argo CD is disarmed (Applications
#  stripped of their cascade-delete finalizers and then deleted) before any
#  Helm uninstall happens.
#
# ─── SAFE ORDER ──────────────────────────────────────────────────────────────
#
#  1. Disarm Argo CD (remove Application finalizers, delete Applications,
#     so self-heal stops fighting us)
#  2. Delete the CNPG Cluster CR (operator cleans its own PVCs via finalizer)
#  3. Wait for CNPG PVCs to confirm gone
#  4. Delete remaining PVCs across all namespaces (while CSI driver still runs)
#  5. Wait for all PVs to be gone (= EBS DeleteVolume confirmed)
#  6. Cross-check AWS for any orphaned EBS volumes via the cluster tag
#  7. Uninstall Helm releases in reverse dependency order
#  8. Remove Argo CD itself
#  9. Remove Cilium last (keeps pod networking alive until everything else is done)
# 10. Delete namespaces
#
# ─── PRE-FLIGHT ──────────────────────────────────────────────────────────────
set -euo pipefail

# AWS region — used only for the orphan check (step 6).
# Reads from environment or falls back to the instance metadata endpoint.
AWS_REGION="${AWS_REGION:-}"
# Optional: set to your cluster name tag value if you tag EBS volumes with
# kubernetes.io/cluster/<name>=owned. Used to scope the orphan search.
CLUSTER_NAME="${CLUSTER_NAME:-}"

# How long to wait (seconds) for PVs/PVCs to disappear before giving up
PV_WAIT_TIMEOUT="${PV_WAIT_TIMEOUT:-120}"

ARGOCD_NAMESPACE="argocd"
APP_NAMESPACE="fastapi"
DB_NAMESPACE="db"
MONITORING_NAMESPACE="monitoring"
OTEL_NAMESPACE="observability"
INGRESS_NAMESPACE="ingress-nginx"
KEDA_NAMESPACE="keda"
CNPG_NAMESPACE="cnpg-system"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[1;34m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}══════════════════════════════════════════════════════${NC}"; \
          echo -e "${BLUE}  $1${NC}"; \
          echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"; }
info()  { echo -e "  ${GREEN}▶${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
error() { echo -e "  ${RED}✖${NC} $1"; }

require_command() {
  if ! command -v "$1" &>/dev/null; then
    error "Required command not found: $1"
    exit 1
  fi
}

helm_uninstall() {
  local release="$1" namespace="$2"
  if helm status "$release" -n "$namespace" &>/dev/null; then
    info "Uninstalling helm release '$release' from '$namespace'…"
    helm uninstall "$release" -n "$namespace" --wait --timeout 3m
  else
    info "Release '$release' not found in '$namespace' — skipping."
  fi
}

# Remove Argo CD cascade-delete finalizer and delete an Application
argocd_delete_app() {
  local name="$1"
  if kubectl get application "$name" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    info "Removing finalizer from Application '$name'…"
    kubectl patch application "$name" -n "$ARGOCD_NAMESPACE" \
      -p '{"metadata":{"finalizers":[]}}' --type=merge
    kubectl delete application "$name" -n "$ARGOCD_NAMESPACE" --ignore-not-found
  fi
}

# Wait until there are no PVCs left in a namespace, up to $PV_WAIT_TIMEOUT sec
wait_pvcs_gone() {
  local namespace="$1"
  local elapsed=0
  info "Waiting for PVCs in '$namespace' to disappear (max ${PV_WAIT_TIMEOUT}s)…"
  while true; do
    local count
    count=$(kubectl get pvc -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -eq 0 ]] && break
    if [[ "$elapsed" -ge "$PV_WAIT_TIMEOUT" ]]; then
      warn "Timeout waiting for PVCs in '$namespace' — listing remaining:"
      kubectl get pvc -n "$namespace" 2>/dev/null || true
      break
    fi
    sleep 5; elapsed=$((elapsed + 5))
    echo -n "    [$elapsed s] ${count} PVC(s) remaining in ${namespace}…"$'\r'
  done
  echo
}

# Wait until all cluster-wide PVs are gone
wait_all_pvs_gone() {
  local elapsed=0
  info "Waiting for all PVs to be fully released/deleted (max ${PV_WAIT_TIMEOUT}s)…"
  while true; do
    local count
    count=$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -eq 0 ]] && break
    if [[ "$elapsed" -ge "$PV_WAIT_TIMEOUT" ]]; then
      warn "Timeout — PVs still present. Listing:"
      kubectl get pv 2>/dev/null || true
      break
    fi
    sleep 5; elapsed=$((elapsed + 5))
    echo -n "    [$elapsed s] ${count} PV(s) still present…"$'\r'
  done
  echo
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────
for cmd in kubectl helm; do require_command "$cmd"; done

echo
warn "This will PERMANENTLY destroy ALL cluster resources and AWS EBS volumes."
warn "Namespaces removed: ${APP_NAMESPACE}, ${DB_NAMESPACE}, ${MONITORING_NAMESPACE},"
warn "  ${OTEL_NAMESPACE}, ${INGRESS_NAMESPACE}, ${KEDA_NAMESPACE}, ${CNPG_NAMESPACE},"
warn "  ${ARGOCD_NAMESPACE}, and relevant kube-system components."

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Disarm Argo CD (stop self-heal fighting us)
# ─────────────────────────────────────────────────────────────────────────────
step "1/9  Disarming Argo CD (removing Applications)"

if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
  # Delete app-facing Applications first (they're namespace-scoped only,
  # safe to remove early)
  for app in fastapi-app postgresql; do
    argocd_delete_app "$app"
  done

  # Then infra Applications — strip finalizers so they don't cascade-delete
  # cluster resources (we're about to do that ourselves in the right order)
  for app in \
    grafana-dashboards loki tempo \
    kube-prometheus-stack otel-collectors \
    keda cnpg-operator opentelemetry-operator \
    ingress-nginx aws-ebs-csi-driver cluster-autoscaler \
    prometheus-operator-crds cilium; do
    argocd_delete_app "$app"
  done

  # root-app last (it owns the child Applications)
  argocd_delete_app "root-app"

  info "All Applications removed — Argo CD is now passive."
else
  info "Namespace '$ARGOCD_NAMESPACE' not found — Argo CD may not be installed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Delete CNPG Cluster CR (operator handles its own PVC cleanup)
# ─────────────────────────────────────────────────────────────────────────────
step "2/9  Deleting CNPG Cluster CR (operator will delete its PVCs)"

if kubectl get cluster pg-cluster -n "$DB_NAMESPACE" &>/dev/null; then
  info "Deleting CNPG Cluster 'pg-cluster' in '$DB_NAMESPACE'…"
  kubectl delete cluster pg-cluster -n "$DB_NAMESPACE" --timeout=90s || {
    warn "Cluster deletion timed out or failed. Checking for stuck finalizer…"
    kubectl patch cluster pg-cluster -n "$DB_NAMESPACE" \
      -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete cluster pg-cluster -n "$DB_NAMESPACE" \
      --ignore-not-found --timeout=30s || true
  }
  wait_pvcs_gone "$DB_NAMESPACE"
else
  info "CNPG Cluster 'pg-cluster' not found — skipping."
fi

# Remove CNPG Helm release while operator pods are still alive to process any
# remaining cleanup work
helm_uninstall postgresql "$DB_NAMESPACE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Delete all remaining PVCs (EBS CSI driver still running)
# ─────────────────────────────────────────────────────────────────────────────
step "3/9  Deleting all PVCs (reclaimPolicy=Delete → EBS volumes auto-deleted)"

# These are the namespaces that actually have PVCs per your values files:
#   monitoring  → Grafana (1Gi) + Prometheus StatefulSet (1Gi)
#   observability → Tempo ingester (1Gi)
#   db          → was handled by CNPG above, but double-check
# (fastapi, ingress-nginx, keda, cnpg-system have no PVCs in this setup)
for ns in "$MONITORING_NAMESPACE" "$OTEL_NAMESPACE" "$DB_NAMESPACE" "$APP_NAMESPACE"; do
  if ! kubectl get namespace "$ns" &>/dev/null; then
    info "Namespace '$ns' doesn't exist — skipping PVC deletion."
    continue
  fi
  pvc_count=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$pvc_count" -gt 0 ]]; then
    info "Deleting $pvc_count PVC(s) in '$ns'…"
    # Remove any stuck finalizers first — they can block PVC deletion while
    # the pod that mounted the volume is gone but the unmount event was missed
    for pvc in $(kubectl get pvc -n "$ns" -o name 2>/dev/null); do
      kubectl patch "$pvc" -n "$ns" \
        -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    kubectl delete pvc --all -n "$ns" --timeout=60s || true
    wait_pvcs_gone "$ns"
  else
    info "No PVCs in '$ns'."
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Wait for all PVs to be gone (= EBS DeleteVolume confirmed)
# ─────────────────────────────────────────────────────────────────────────────
step "4/9  Waiting for all PersistentVolumes to be deleted"
wait_all_pvs_gone

# Any PVs stuck in Released/Failed state didn't get their EBS volumes
# cleaned up — we handle those in step 5
STUCK_PVS=$(kubectl get pv --no-headers 2>/dev/null | awk '{print $1}' || true)
if [[ -n "$STUCK_PVS" ]]; then
  warn "Some PVs are still present. Forcing deletion and flagging for AWS check:"
  for pv in $STUCK_PVS; do
    local_volume_id=$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)
    warn "  PV: $pv  →  EBS volumeID: ${local_volume_id:-unknown}"
    kubectl delete pv "$pv" --timeout=30s 2>/dev/null || \
      kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — Cross-check AWS for orphaned EBS volumes
# ─────────────────────────────────────────────────────────────────────────────
step "5/9  Checking AWS for orphaned EBS volumes"

if ! command -v aws &>/dev/null; then
  warn "'aws' CLI not found — skipping orphan check."
  warn "Run this manually after teardown:"
  warn "  aws ec2 describe-volumes --region <region> \\"
  warn "    --filters Name=status,Values=available \\"
  warn "              Name=tag-key,Values=kubernetes.io/created-for/pvc/name"
else
  # Resolve region if not set
  if [[ -z "$AWS_REGION" ]]; then
    AWS_REGION=$(curl -sf --connect-timeout 2 \
      http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
  fi
  if [[ -z "$AWS_REGION" ]]; then
    warn "Could not determine AWS region. Set AWS_REGION env var and re-run the"
    warn "orphan check manually:"
    warn "  aws ec2 describe-volumes --region <region> \\"
    warn "    --filters Name=status,Values=available \\"
    warn "              Name=tag-key,Values=kubernetes.io/created-for/pvc/name"
  else
    info "Checking region ${AWS_REGION} for available EBS volumes tagged by this cluster…"

    # Scope filter: if CLUSTER_NAME is set, look for volumes tagged with
    # kubernetes.io/cluster/<name>=owned (standard k8s cloud-provider tag).
    # Otherwise, look for any 'available' volume tagged by the CSI driver.
    filters=(
      "Name=status,Values=available"
      "Name=tag-key,Values=kubernetes.io/created-for/pvc/name"
    )
    if [[ -n "$CLUSTER_NAME" ]]; then
      filters+=("Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned")
    fi

    ORPHANS=$(aws ec2 describe-volumes \
      --region "$AWS_REGION" \
      --filters "${filters[@]}" \
      --query 'Volumes[*].{ID:VolumeId,Size:Size,PVC:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' \
      --output table 2>/dev/null || true)

    if [[ -z "$ORPHANS" || "$ORPHANS" == *"None"* ]]; then
      info "✅ No orphaned EBS volumes found."
    else
      warn "Orphaned EBS volumes found (status=available, PVC tag present):"
      echo "$ORPHANS"
      echo
      read -r -p "  Delete ALL listed orphaned volumes? [y/N]: " DELETE_ORPHANS
      if [[ "${DELETE_ORPHANS,,}" == "y" ]]; then
        ORPHAN_IDS=$(aws ec2 describe-volumes \
          --region "$AWS_REGION" \
          --filters "${filters[@]}" \
          --query 'Volumes[*].VolumeId' \
          --output text 2>/dev/null || true)
        for vol_id in $ORPHAN_IDS; do
          info "Deleting EBS volume ${vol_id}…"
          aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$vol_id" \
            && info "  Deleted: $vol_id" \
            || warn "  Failed to delete: $vol_id (may already be gone)"
        done
      else
        warn "Skipped orphan deletion. Delete manually:"
        warn "  aws ec2 delete-volume --region ${AWS_REGION} --volume-id <vol-id>"
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — Uninstall Helm releases (reverse dependency order)
# ─────────────────────────────────────────────────────────────────────────────
step "6/9  Uninstalling Helm releases (reverse dependency order)"

# Wave 40 / 30 — app + backends
helm_uninstall fastapi-app   "$APP_NAMESPACE"
helm_uninstall loki          "$OTEL_NAMESPACE"
helm_uninstall tempo         "$OTEL_NAMESPACE"
helm_uninstall otel          "$OTEL_NAMESPACE"

# Wave 20
helm_uninstall kube-prometheus-stack "$MONITORING_NAMESPACE"

# Wave 10 — operators + infra (after the CRs they own are gone)
helm_uninstall opentelemetry-operator "$OTEL_NAMESPACE"
helm_uninstall keda          "$KEDA_NAMESPACE"
helm_uninstall cnpg          "$CNPG_NAMESPACE"
helm_uninstall ingress-nginx "$INGRESS_NAMESPACE"
helm_uninstall cluster-autoscaler "kube-system"

# EBS CSI driver — must stay alive until ALL PVs are confirmed gone.
# If this uninstalls while PVs still exist, DeleteVolume calls fail silently.
info "Confirming no PVs remain before removing EBS CSI driver…"
pv_check=$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$pv_check" -gt 0 ]]; then
  warn "$pv_check PV(s) still present — listing before removing CSI driver:"
  kubectl get pv 2>/dev/null || true
  warn "These EBS volumes may be orphaned after CSI driver removal."
  warn "Check AWS console for 'available' volumes after teardown."
fi
helm_uninstall aws-ebs-csi-driver "kube-system"

# Wave 0 — CRDs
helm_uninstall prometheus-operator-crds "$MONITORING_NAMESPACE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7 — Remove Argo CD
# ─────────────────────────────────────────────────────────────────────────────
step "7/9  Removing Argo CD"
helm_uninstall argocd "$ARGOCD_NAMESPACE"
# Delete any orphaned AppProject or Application CRs that helm uninstall
# might leave behind (Argo CD installs its own CRDs)
kubectl delete applications --all -n "$ARGOCD_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete appprojects --all -n "$ARGOCD_NAMESPACE" --ignore-not-found 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 8 — Remove Cilium (last — keep pod networking alive until now)
# ─────────────────────────────────────────────────────────────────────────────
step "8/9  Removing Cilium (CNI — done last to preserve pod networking)"
helm_uninstall cilium "kube-system"
# Cilium installs several CRDs that need cleaning up
kubectl delete crd -l app.kubernetes.io/part-of=cilium --ignore-not-found 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 9 — Delete namespaces
# ─────────────────────────────────────────────────────────────────────────────
step "9/9  Deleting namespaces"
for ns in \
  "$APP_NAMESPACE" \
  "$DB_NAMESPACE" \
  "$MONITORING_NAMESPACE" \
  "$OTEL_NAMESPACE" \
  "$INGRESS_NAMESPACE" \
  "$KEDA_NAMESPACE" \
  "$CNPG_NAMESPACE" \
  "$ARGOCD_NAMESPACE"; do
  if kubectl get namespace "$ns" &>/dev/null; then
    info "Deleting namespace '$ns'…"
    kubectl delete namespace "$ns" --ignore-not-found --timeout=60s || \
      warn "Namespace '$ns' may be stuck (check for leftover finalizers)."
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Teardown complete — final state:${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"

echo
info "Remaining PVCs (should be empty):"
kubectl get pvc -A 2>/dev/null || true

echo
info "Remaining PVs (should be empty):"
kubectl get pv 2>/dev/null || true

echo
info "Remaining Helm releases:"
helm list -A 2>/dev/null || true

echo
if command -v aws &>/dev/null && [[ -n "$AWS_REGION" ]]; then
  info "Remaining 'available' EBS volumes tagged by k8s (should be empty):"
  aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=status,Values=available" \
               "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'Volumes[*].{ID:VolumeId,Size:Size,PVC:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' \
    --output table 2>/dev/null || warn "Could not query AWS — check manually."
fi

echo
warn "EC2 nodes are still running. Terminate them via the AWS console or:"
warn "  aws ec2 terminate-instances --region ${AWS_REGION:-<region>} --instance-ids <id> …"
warn "Don't forget to also delete:"
warn "  - The cluster's IAM roles / instance profiles"
warn "  - Any Route53 records pointing at node IPs"
warn "  - Security groups (if not cleaned up by cloudformation/terraform)"