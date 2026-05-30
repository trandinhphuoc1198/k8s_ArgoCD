# k8s_ArgoCD

Helm-based deployment assets for an existing self-managed Kubernetes cluster on EC2.

This repository deploys:
- `metrics-server` for HPA metrics
- `ingress-nginx` as the in-cluster nginx load balancer, exposed with `NodePort`
- `kube-prometheus-stack` for Prometheus and Grafana
- A FastAPI application chart for `gintaku98/k8s_fastapi:6b1b515a4ba21d122e4f33e3381c866a48ba5098`

## Prerequisites

- Existing Kubernetes cluster and `kubectl` context pointing at it
- Helm 3
- EBS CSI driver installed with a usable StorageClass
- An ALB or other upstream load balancer that forwards to the `ingress-nginx` NodePorts

## Layout

- `charts/fastapi-app`: application chart
- `k8s/helm/metrics-server-values.yaml`: metrics-server values for self-managed nodes
- `k8s/helm/ingress-nginx-values.yaml`: ingress-nginx values with `NodePort` exposure
- `k8s/helm/kube-prometheus-stack-values.yaml`: monitoring stack values
- `deploy.sh`: repeatable Helm install and upgrade flow

## FastAPI configuration

The chart expects database settings through a Kubernetes Secret. By default, it creates one from chart values:

- `DB_HOST`
- `DB_PORT`
- `DB_USER`
- `DB_PASSWORD`
- `DB_NAME`

Update [charts/fastapi-app/values.yaml](c:/Users/PhuocTD6/Desktop/k8s_ArgoCD/charts/fastapi-app/values.yaml) or supply an override file before deploying. If you already manage secrets separately, set `database.existingSecret` and disable secret creation.

## Deploy

Run:

```bash
./deploy.sh
```

Optional environment variables:

- `APP_NAMESPACE` defaults to `fastapi`
- `MONITORING_NAMESPACE` defaults to `monitoring`
- `INGRESS_NAMESPACE` defaults to `ingress-nginx`
- `STORAGE_CLASS` defaults to `ebs-csi`
- `APP_VALUES_FILE` points to an additional Helm values override file

## Verify

```bash
kubectl get pods -A
kubectl get svc -n ingress-nginx
kubectl get deploy,svc,ing,hpa -n fastapi
kubectl top pods -n fastapi
kubectl get pvc -n monitoring
```

Expected outcomes:

- FastAPI starts at 2 replicas
- `ingress-nginx-controller` is exposed via `NodePort`
- HPA targets average CPU utilization at 50%
- Prometheus and Grafana PVCs bind against the EBS-backed StorageClass
- The FastAPI chart creates a `ServiceMonitor` so the monitoring stack can scrape the app once the operator is installed

## Notes

- The FastAPI image port is assumed to be `8000`. Override `containerPort` if the image listens elsewhere.
- Default probes use a TCP socket on the container port because the image health endpoints are not yet confirmed.
- Grafana is exposed internally by default as a `ClusterIP` service. You can either use `kubectl port-forward` or add ingress settings in the monitoring values file.