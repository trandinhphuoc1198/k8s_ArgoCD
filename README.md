# FastAPI Kubernetes Deployment

Deploys a FastAPI application on Kubernetes with Nginx Ingress, Horizontal Pod Autoscaling (HPA), and automated metrics collection via Metrics Server.

---

## Architecture

```
Internet
   │
   ▼
AWS ELB (LoadBalancer)
   │
   ▼
Nginx Ingress Controller (ingress-nginx namespace)
   │
   ▼
Ingress Rule → fastapi-service (ClusterIP :80)
   │
   ▼
FastAPI Pods (namespace: fastapi, containerPort: 8000)
   │
   ▼
HPA ← Metrics Server (CPU utilization target: 50%)
```

---

## Prerequisites

| Tool      | Min Version | Purpose                      |
|-----------|-------------|------------------------------|
| `kubectl` | v1.24+      | Cluster management           |
| `kustomize` | v5+       | Manifest management (bundled with kubectl) |
| Kubernetes cluster | 1.24+ | EKS, GKE, kubeadm, etc. |

---

## Repository Structure

```
k8s_ArgoCD/
├── deploy.sh                          # One-shot deployment script
├── README.md
└── k8s/
    ├── base/                          # Application manifests (kustomize base)
    │   ├── kustomization.yaml         # Kustomize entry point
    │   ├── namespace.yaml             # fastapi namespace
    │   ├── deployment.yaml            # FastAPI Deployment (2 replicas)
    │   ├── service.yaml               # ClusterIP Service (port 80 → 8000)
    │   ├── ingress.yaml               # Nginx Ingress rule
    │   └── hpa.yaml                   # HPA (min 2, max 5 pods, 50% CPU)
    └── prerequisites/
        ├── metrics-server.yaml        # Metrics Server + APIService
        └── nginx-ingress-controller.yaml  # Nginx Ingress Controller (DaemonSet)
```

---

## Quick Start

```bash
# Make the script executable and run it
chmod +x deploy.sh
./deploy.sh
```

The script performs these steps in order:
1. Installs Metrics Server (required for HPA)
2. Waits for Metrics Server to become ready
3. Installs Nginx Ingress Controller
4. Waits for Nginx Ingress Controller to become ready
5. Deploys the FastAPI application via Kustomize
6. Verifies the deployment

---

## Manual Deployment

### Step 1 — Install prerequisites

```bash
kubectl apply -f k8s/prerequisites/metrics-server.yaml
kubectl apply -f k8s/prerequisites/nginx-ingress-controller.yaml
```

Wait for readiness:

```bash
kubectl wait --for=condition=ready pod \
  -l k8s-app=metrics-server -n kube-system --timeout=120s

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=120s
```

### Step 2 — Deploy the application

```bash
kubectl apply -k k8s/base/
```

### Step 3 — Verify

```bash
kubectl get all -n fastapi
kubectl get hpa -n fastapi
kubectl get ingress -n fastapi
```

---

## Application Details

| Property         | Value                                                                 |
|------------------|-----------------------------------------------------------------------|
| Image            | `gintaku98/k8s_fastapi:6b1b515a4ba21d122e4f33e3381c866a48ba5098`    |
| Namespace        | `fastapi`                                                             |
| Container port   | `8000`                                                                |
| Service port     | `80` (ClusterIP)                                                      |
| Health endpoint  | `/health`                                                             |
| Ingress host     | `fast-api-k8s-1011545333.ap-northeast-1.elb.amazonaws.com`           |

### Resource Limits (per pod)

| Resource | Request | Limit  |
|----------|---------|--------|
| CPU      | 100m    | 200m   |
| Memory   | 64Mi    | 128Mi  |

### Horizontal Pod Autoscaler

| Setting            | Value |
|--------------------|-------|
| Min replicas       | 2     |
| Max replicas       | 5     |
| CPU target         | 50%   |

---

## Accessing the Application

```bash
# Get the LoadBalancer external IP/hostname
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Test the API
curl http://fast-api-k8s-1011545333.ap-northeast-1.elb.amazonaws.com/

# Check health endpoint
curl http://fast-api-k8s-1011545333.ap-northeast-1.elb.amazonaws.com/health
```

---

## Monitoring & Operations

```bash
# Watch pod status
kubectl get pods -n fastapi -w

# Watch HPA scaling activity
kubectl get hpa -n fastapi --watch

# Check CPU/memory usage (requires Metrics Server to be ready ~1-2 min after deploy)
kubectl top pods -n fastapi
kubectl top nodes

# View application logs
kubectl logs -n fastapi -l app=fastapi --tail=100 -f

# Describe the HPA for scaling events
kubectl describe hpa fastapi-hpa -n fastapi
```

---

## Cleanup

```bash
# Remove the FastAPI application
kubectl delete -k k8s/base/

# Remove prerequisites
kubectl delete -f k8s/prerequisites/nginx-ingress-controller.yaml
kubectl delete -f k8s/prerequisites/metrics-server.yaml
```

---

## Troubleshooting

### Pods not starting

```bash
kubectl describe pod -n fastapi -l app=fastapi
kubectl logs -n fastapi -l app=fastapi --previous
```

### HPA showing `<unknown>` for CPU metrics

Metrics Server may not be ready yet. Wait 1-2 minutes after deployment and check:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
```

### Ingress not routing traffic

Verify the Nginx Ingress Controller is running and the Service has an external IP:

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

### ImagePullBackOff

Confirm the image tag is reachable from your cluster's nodes:

```bash
kubectl describe pod -n fastapi <pod-name>
```
