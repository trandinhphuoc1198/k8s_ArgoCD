#!/usr/bin/env bash
#
# init.sh — Helmfile Bootstrap Script
# Location: repo root (same level as helmfile/)
#
# Replaces the ArgoCD init.sh. Installs prerequisites, then uses
# helmfile to deploy the full cluster stack in wave order.
#
# Usage:
#   chmod +x init.sh && ./init.sh
#
# Optional env overrides:
#   HELMFILE_VERSION=1.1.0 ./init.sh
#   HELM_VERSION=3.21.2    ./init.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELMFILE_DIR="$REPO_ROOT/helmfile"

HELMFILE_VERSION="${HELMFILE_VERSION:-1.1.0}"
HELM_VERSION="${HELM_VERSION:-3.21.2}"
ARCH="$(uname -m)"

# Normalise arch: helmfile releases use 'amd64' and 'arm64'
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)
    echo "❌ Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[1;34m'
NC='\033[0m'

info()    { echo -e "\n${BLUE}==>${NC} \033[1m$1\033[0m"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }

require() {
  command -v "$1" &>/dev/null || {
    echo "❌ Required tool not found: $1"
    exit 1
  }
}

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}     Helmfile Cluster Bootstrap                  ${NC}"
echo -e "${BLUE}==================================================${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Check hard prerequisites
# ─────────────────────────────────────────────────────────────────────────────
info "Step 1/4: Checking prerequisites..."
require kubectl
require curl
require tar

# Verify kubeconfig is usable before spending time installing tools
kubectl cluster-info --request-timeout=10s >/dev/null \
  || { echo "❌ kubectl cannot reach the cluster. Check your kubeconfig."; exit 1; }

success "kubectl can reach the cluster"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Install Helm (if not already installed or wrong version)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 2/4: Installing Helm ${HELM_VERSION}..."

if command -v helm &>/dev/null; then
  CURRENT_HELM="$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
  echo "  Found existing Helm: ${CURRENT_HELM}"
else
  echo "  Helm not found — installing..."
  curl -fsSL -o /tmp/get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  DESIRED_TAG="v${HELM_VERSION}" /tmp/get_helm.sh
  rm /tmp/get_helm.sh
fi
success "Helm ready: $(helm version --short)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Install Helmfile + helm-diff plugin
# ─────────────────────────────────────────────────────────────────────────────
info "Step 3/4: Installing Helmfile ${HELMFILE_VERSION}..."

if command -v helmfile &>/dev/null; then
  CURRENT_HF="$(helmfile --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  echo "  Found existing helmfile: v${CURRENT_HF}"
else
  echo "  Downloading helmfile v${HELMFILE_VERSION} (${ARCH})..."
  HELMFILE_URL="https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz"
  curl -Lo /tmp/helmfile.tar.gz "$HELMFILE_URL"
  tar -xzf /tmp/helmfile.tar.gz -C /tmp helmfile
  chmod +x /tmp/helmfile
  sudo mv /tmp/helmfile /usr/local/bin/helmfile
  rm /tmp/helmfile.tar.gz
fi
success "Helmfile ready: $(helmfile --version)"

# Install helm-diff plugin (required by helmfile apply/diff)
if helm plugin list | grep -q '^diff'; then
  echo "  helm-diff already installed — skipping"
else
  echo "  Installing helm-diff plugin..."
  helm plugin install https://github.com/databus23/helm-diff
fi
success "helm-diff ready"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Deploy cluster with helmfile
# ─────────────────────────────────────────────────────────────────────────────
info "Step 4/4: Deploying cluster stack via helmfile..."
echo "  Working directory: ${HELMFILE_DIR}"

cd "$HELMFILE_DIR"

# Update all helm repos declared in helmfile.yaml
echo "  Syncing Helm repositories..."
helmfile repos

# Deploy everything in wave order (cilium → operators → observability → apps)
helmfile apply

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}         Bootstrap Complete!                     ${NC}"
echo -e "${GREEN}  Helmfile is now managing the cluster stack.    ${NC}"
echo -e "${GREEN}==================================================${NC}"
echo
echo "Useful commands:"
echo "  helmfile list                   # status of all releases"
echo "  helmfile diff                   # see pending changes"
echo "  helmfile apply -l wave=50       # redeploy a single wave"
echo "  helmfile apply -l name=tempo    # redeploy a single release"