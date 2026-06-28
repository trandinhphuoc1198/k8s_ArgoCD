# Grafana Dashboard ConfigMaps

Four dashboards generated from your k8s setup. Each is a standalone ConfigMap
that the **kube-prometheus-stack Grafana sidecar** picks up automatically via
the `grafana_dashboard: "1"` label.

## Files

| File | Dashboard | UID |
|------|-----------|-----|
| `01-fastapi-dashboard-configmap.yaml` | FastAPI App | `fastapi-app` |
| `02-k8s-cluster-dashboard-configmap.yaml` | Kubernetes Cluster | `k8s-cluster` |
| `03-otel-collector-dashboard-configmap.yaml` | OTel Collector Pipeline | `otel-collector` |
| `04-tempo-dashboard-configmap.yaml` | Tempo Distributed Tracing | `tempo-distributed` |

## Apply

```bash
# Apply all at once
kubectl apply -f grafana-dashboards/

# Or one by one
kubectl apply -f grafana-dashboards/01-fastapi-dashboard-configmap.yaml
kubectl apply -f grafana-dashboards/02-k8s-cluster-dashboard-configmap.yaml
kubectl apply -f grafana-dashboards/03-otel-collector-dashboard-configmap.yaml
kubectl apply -f grafana-dashboards/04-tempo-dashboard-configmap.yaml
```

The Grafana sidecar watches for ConfigMaps with the label `grafana_dashboard: "1"`
in the `monitoring` namespace and hot-loads them — no Grafana restart needed.

## Verify the sidecar picked it up

```bash
# Check sidecar logs
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=20

# Confirm ConfigMaps are present
kubectl get configmap -n monitoring -l grafana_dashboard=1
```

## Dashboard details

### 01 — FastAPI App
- RPS total / 4xx / 5xx timeseries
- **KEDA trigger overlays**: per-pod RPS vs threshold (10 req/s) and P95 latency
  vs threshold (0.5 s) — exactly matching your `scaledobject.yaml` queries
- P50 / P95 / P99 latency
- 5xx error rate %
- Replica count: actual vs desired, with dashed min (1) and max (5) lines
- Per-pod CPU and memory
- Stat row: current RPS, P95 latency, ready pods, error rate

### 02 — Kubernetes Cluster
- Node CPU / Memory / Disk / Network I/O — filterable by `$node`
- Pod count by namespace (fastapi / monitoring / observability)
- Pod restart heatmap
- CPU + Memory requests vs limits bargauge by namespace
- EBS CSI PersistentVolume usage %
- Deployment availability (desired vs ready)
- Stat row: total nodes, not-ready nodes, running/pending/failed pods

### 03 — OTel Collector Pipeline
- DaemonSet (`otel-collector-ds`): spans accepted/refused per node
- Aggregator (`otel-collector-agg`): spans exported to Tempo, logs to Loki
- **Tail sampling**: sampled vs dropped, broken out by policy
  (errors-policy / slow-policy / default-policy matching your `values.yaml`)
- filelog receiver: log records ingested from `fastapi` namespace
- Collector RSS memory and CPU
- Exporter queue size with thresholds
- Traces-in-buffer vs `numTraces` limit (10 000)
- Stat row: spans/s received, spans/s → Tempo, logs/s → Loki, export failures/s

### 04 — Tempo Distributed Tracing
- Distributor: spans/s and traces/s received
- Ingester: live traces in memory, WAL flush rate/failures to S3
- Query frontend: request rate and P95 latency by operation
- **S3 backend**: write + read ops/s and P95 latency (bucket: `tempo-s3-phuoctd6`)
- Compactor: bytes compacted/s
- MetricsGenerator: service-graph edges/s and span-metrics calls/s
  (processors: service-graphs, span-metrics, local-blocks)
- Stat row: spans/s, flush failures, S3 write P95, live trace count

## Datasource UIDs

All dashboards use the kube-prometheus-stack defaults:

| Signal | UID |
|--------|-----|
| Prometheus | `prometheus` |
| Loki | `loki` |
| Tempo | `tempo` |

If your UIDs differ, do a find-replace across all four files before applying.

## Tip: link Grafana to Tempo for trace drill-down

In the Loki datasource settings in Grafana, add a **Derived Field** for
`trace_id` pointing to your Tempo datasource. This enables one-click
log → trace navigation from Explore.