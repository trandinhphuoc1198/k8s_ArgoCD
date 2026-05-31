#Requires -Version 5.1

param(
    [string]$APP_NAMESPACE = "fastapi",
    [string]$MONITORING_NAMESPACE = "monitoring",
    [string]$INGRESS_NAMESPACE = "ingress-nginx",
    [string]$STORAGE_CLASS = "ebs-csi",
    [string]$APP_VALUES_FILE = ""
)

$ErrorActionPreference = 'Stop'

$ROOT_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Test-CommandExists {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Require-Command {
    param([string]$Command)
    if (-not (Test-CommandExists $Command)) {
        Write-Error "missing required command: $Command" -ErrorAction Stop
    }
}

Require-Command helm
Require-Command kubectl

Write-Host "Adding Helm repositories..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ *> $null -ErrorAction SilentlyContinue
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx *> $null -ErrorAction SilentlyContinue
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts *> $null -ErrorAction SilentlyContinue
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver *> $null -ErrorAction SilentlyContinue
helm repo update

Write-Host "Installing metrics-server..."
helm upgrade --install metrics-server metrics-server/metrics-server `
  --namespace kube-system `
  --values "$ROOT_DIR\k8s\helm\metrics-server-values.yaml"

Write-Host "Installing AWS EBS CSI driver..."
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver `
  --namespace kube-system `
  --values "$ROOT_DIR\k8s\helm\ebs-csi-values.yaml"

Write-Host "Waiting for EBS CSI deployment..."
kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=120s
kubectl rollout status daemonset/ebs-csi-node -n kube-system --timeout=120s


Write-Host "Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
  --namespace "$MONITORING_NAMESPACE" `
  --create-namespace `
  --values "$ROOT_DIR\k8s\helm\kube-prometheus-stack-values.yaml" `
  --set grafana.persistence.storageClassName="$STORAGE_CLASS" `
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$STORAGE_CLASS"


Write-Host "Installing ingress-nginx..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace "$INGRESS_NAMESPACE" `
  --create-namespace `
  --values "$ROOT_DIR\k8s\helm\ingress-nginx-values.yaml"

Write-Host "Installing FastAPI application..."
$app_args = @(
    "upgrade", "--install", "fastapi-app", "$ROOT_DIR\charts\fastapi-app",
    "--namespace", "$APP_NAMESPACE",
    "--create-namespace"
)

if ([string]::IsNullOrWhiteSpace($APP_VALUES_FILE) -eq $false) {
    $app_args += @("--values", "$APP_VALUES_FILE")
}

& helm @app_args

Write-Host "Deployment finished." -ForegroundColor Green
Write-Host ""
Write-Host "Verify NodePorts: kubectl get svc -n ${INGRESS_NAMESPACE}"
Write-Host "Verify app and HPA: kubectl get deploy,svc,ing,hpa -n ${APP_NAMESPACE}"
Write-Host "Verify metrics: kubectl top pods -n ${APP_NAMESPACE}"
Write-Host "Verify monitoring: kubectl get pods,pvc -n ${MONITORING_NAMESPACE}"
Write-Host ""
Write-Host "Cluster Status:" -ForegroundColor Cyan
Write-Host ""
Write-Host "📊 Metrics Server:"
kubectl get deployment -n kube-system metrics-server
Write-Host ""
Write-Host "🔀 Ingress Controller:"
kubectl get deployment -n ingress-nginx ingress-nginx-controller
Write-Host ""
Write-Host "🚀 FastAPI Application:"
kubectl get deployment -n fastapi fastapi-app
kubectl get pods -n fastapi
Write-Host ""
Write-Host "Autoscaling Status:"
kubectl get hpa -n fastapi
Write-Host ""
Write-Host "Service & Ingress:"
kubectl get svc,ingress -n fastapi
Write-Host ""
Write-Host "📡 Ingress Controller Service:"
kubectl get svc -n ingress-nginx ingress-nginx-controller
Write-Host ""
Write-Host "💡 Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Check your FastAPI pods are in 'Running' state: kubectl get pods -n fastapi"
Write-Host "  2. Check metrics are working: kubectl top pods -n fastapi (may take 1-2 min)"
Write-Host "  3. Get your LoadBalancer IP: kubectl get svc -n ingress-nginx"
Write-Host "  4. Access your app: curl http://fast-api-k8s-1011545333.ap-northeast-1.elb.amazonaws.com/"
Write-Host "  5. Monitor HPA: kubectl get hpa -n fastapi --watch"
Write-Host ""
