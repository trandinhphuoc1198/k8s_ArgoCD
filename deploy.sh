#!/bin/bash
# FastAPI K8s Deployment Script
# Installs prerequisites and deploys the FastAPI application

set -e

echo "=================================================="
echo "FastAPI K8s Deployment - Automated Setup"
echo "=================================================="

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

echo ""
echo "Step 1: Installing Metrics Server..."
echo "This is required for HPA (Horizontal Pod Autoscaler) to work"
kubectl apply -f k8s/prerequisites/metrics-server.yaml

echo ""
echo "Step 2: Waiting for Metrics Server to be ready..."
echo "This may take 30-60 seconds..."
kubectl wait --for=condition=ready pod \
  -l k8s-app=metrics-server \
  -n kube-system \
  --timeout=120s \
  2>/dev/null || echo "⚠️  Metrics Server still starting (may take longer on slow clusters)"

echo ""
echo "Step 3: Installing Nginx Ingress Controller..."
echo "This is required for Ingress routing to work"
kubectl apply -f k8s/prerequisites/nginx-ingress-controller.yaml

echo ""
echo "Step 4: Waiting for Nginx Ingress Controller to be ready..."
sleep 10
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=ingress-nginx \
  -n ingress-nginx \
  --timeout=120s \
  2>/dev/null || echo "⚠️  Nginx Ingress still starting"

echo ""
echo "Step 5: Deploying FastAPI Application..."
kubectl apply -k k8s/base/

echo ""
echo "Step 6: Verifying Deployment..."
echo ""
echo "Waiting for FastAPI pods to be ready..."
kubectl wait --for=condition=ready pod \
  -l app=fastapi \
  -n fastapi \
  --timeout=120s \
  2>/dev/null || echo "⚠️  Pods still starting"

echo ""
echo "=================================================="
echo "✅ Deployment Complete!"
echo "=================================================="
echo ""
echo "Cluster Status:"
echo ""
echo "📊 Metrics Server:"
kubectl get deployment -n kube-system metrics-server
echo ""
echo "🔀 Ingress Controller:"
kubectl get daemonset -n ingress-nginx ingress-nginx-controller
echo ""
echo "🚀 FastAPI Application:"
kubectl get deployment -n fastapi fastapi-app
kubectl get pods -n fastapi
echo ""
echo "Autoscaling Status:"
kubectl get hpa -n fastapi
echo ""
echo "Service & Ingress:"
kubectl get svc,ingress -n fastapi
echo ""
echo "📡 Ingress Controller Service:"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo ""
echo "💡 Next Steps:"
echo "  1. Check your FastAPI pods are in 'Running' state: kubectl get pods -n fastapi"
echo "  2. Check metrics are working: kubectl top pods -n fastapi (may take 1-2 min)"
echo "  3. Get your LoadBalancer IP: kubectl get svc -n ingress-nginx"
echo "  4. Access your app: curl http://fast-api-k8s-1011545333.ap-northeast-1.elb.amazonaws.com/"
echo "  5. Monitor HPA: kubectl get hpa -n fastapi --watch"
echo ""
