# k8s_ArgoCD

A GitOps-managed Kubernetes platform. A hub/spoke ArgoCD setup deploys a
shared platform layer — CNI, ingress, observability, autoscaling, a
Postgres operator — plus application workloads (`fastapi-app`,
`postgresql`) onto any number of registered spoke clusters.

The platform ships with a full observability stack out of the box:
Prometheus + Grafana (via `kube-prometheus-stack`), Loki for logs, Tempo
for traces, and an OpenTelemetry Collector pipeline wiring them together
with trace/log correlation.

## Two ways to stand this up

Pick one per cluster — don't mix them:

| Path | Use when |
|---|---|
| **[`argocd/`](argocd/README.md)** (GitOps, hub/spoke) | Steady-state or multi-cluster. Auto-sync + self-heal. |

## Repo layout

```
repo-root/
├── argocd/               ← GitOps source of truth — see argocd/README.md
│   ├── root-apps/           # root-hub.yaml, root-spokes.yaml, root-clusters.yaml — applied once, by hand
│   ├── projects/            # AppProjects: platform-hub, platform-infra, platform-apps
│   ├── hub/                 # Applications targeting the hub cluster itself
│   ├── spokes/               # ApplicationSets fanned out to every registered spoke
│   │   ├── infra/             # 00 → 30: CNI, storage, ingress, observability, operators
│   │   └── workloads/         # 40 → 50: postgresql, fastapi-app
│   ├── clusters/             # One ExternalSecret per registered spoke
│   └── bootstrap/            # register-spoke.sh / deregister-spoke.sh, capture-versions.sh
│
│
├── platform/               ← shared infra manifests/values/charts, used by both argocd/ and helmfile/
│   ├── values/
│   │   ├── base/              # config shared by every tier (cert-manager, ingress-nginx)
│   │   ├── hub/                # hub-only overrides
│   │   └── spoke/              # spoke-fleet overrides
│   ├── cert-manager/
│   ├── charts/otel/           # OTel Operator collectors + Instrumentation CR
│   ├── grafana-dashboards/    # ConfigMaps picked up by the Grafana sidecar
│   └── monitoring-configs/    # Cilium/Hubble ServiceMonitors
│
├── services/               ← application Helm charts
│   ├── fastapi-app/
│   ├── postgresql/           # CloudNativePG Cluster + PgBouncer poolers
│   └── _unreleased/          # charts not wired into argocd/ or helmfile/ yet
│
├── init.sh / init-helmfile.sh / tear-down.sh
└── LIMITATIONS.md
```

## Why `platform/values/` is split into `base/`, `hub/`, and `spoke/`

Every file under `platform/values/spoke/` is consumed by an
`argocd/spokes/` ApplicationSet (and mirrored 1:1 by
`helmfile/helmfile.yaml`), so editing one affects **every** registered
spoke cluster. Every file under `platform/values/hub/` is consumed by
exactly one `argocd/hub/*.yaml` Application targeting the hub only.
Keeping them in separate directories makes the blast radius of a change
obvious from the file's path alone.

Two charts — `cert-manager` and `ingress-nginx` — run on **both** the hub
and every spoke, using a base + overlay pattern:

- `platform/values/base/<chart>.yaml` holds config shared by every tier.
- `platform/values/hub/<chart>.yaml` and `platform/values/spoke/<chart>.yaml`
  are each tier's override, layered on top via a second `helm.valueFiles`
  entry.

No Application ever lists a values file from a directory it doesn't own.

## What's deployed

**Platform (per spoke, in sync-wave order):**
Cilium (CNI) → AWS Cloud Controller Manager, Cluster Autoscaler, EBS CSI
driver, cert-manager → ingress-nginx, metrics-server, CNPG operator,
OTel Operator, KEDA → kube-prometheus-stack, OTel collectors →
Loki, Tempo, Grafana dashboards, Cilium/Hubble ServiceMonitors →
postgresql → fastapi-app.

**Application layer:**
- `fastapi-app` — a FastAPI service behind ingress-nginx, auto-scaled by
  KEDA on request-rate and P95-latency Prometheus queries, auto-instrumented
  for tracing via the OTel Operator webhook.
- `postgresql` — a CloudNativePG `Cluster` (1 primary + 1 replica) fronted
  by RW/RO PgBouncer poolers in transaction-pooling mode.

**Observability:** every component exports Prometheus metrics via
ServiceMonitor/PodMonitor; OTel Collectors correlate traces (Tempo) and
logs (Loki) via `trace_id`; Grafana dashboards are auto-provisioned as
ConfigMaps. See [`platform/grafana-dashboards/README.md`](platform/grafana-dashboards/README.md).

## Which init script does what

- `init.sh` — bootstraps Cilium + Cluster Autoscaler by hand, installs
  ArgoCD, then applies `argocd/root-apps/`. The current hub/spoke bootstrap
  procedure is documented in [`argocd/README.md`](argocd/README.md#bootstrap-order)
  and uses `argocd/bootstrap/register-spoke.sh` to onboard each spoke.
- `init-helmfile.sh` — installs `helm`/`helmfile` if missing, then runs
  `helmfile apply` against whatever cluster your kubeconfig points at. No
  ArgoCD involved.
- `tear-down.sh` — aggressive, non-GitOps purge script (deletes ArgoCD
  Applications, force-deletes workloads/PVCs/namespaces). Only for
  scrapping a cluster entirely — **do not** run it against a cluster under
  active ArgoCD self-heal, and never against the hub.

## CI

[`.github/workflows/validate.yml`](.github/workflows/validate.yml) lints
and renders the three local charts (`fastapi-app`, `postgresql`,
`platform/charts/otel`) with the CRD API versions this repo depends on
(`ServiceMonitor`, `PodMonitor`, `ScaledObject`, CNPG `Cluster`/`Pooler`,
OTel `OpenTelemetryCollector`/`Instrumentation`) and scans the rendered
output with Trivy. Keep the `--api-versions` list in sync with any new CRD
your templates gate on — without it, a template guarded by
`.Capabilities.APIVersions.Has` silently renders to nothing and CI won't
catch it.

## Known gaps

See [`LIMITATIONS.md`](LIMITATIONS.md) for the platform-level list (Cilium
VXLAN mode, no NetworkPolicies yet, no service mesh, EC2 IAM not least
privilege, etc). ArgoCD/GitOps-specific gaps — floating chart versions,
`prometheus-operator-crds` not tracked as its own Application, plaintext
`changeme` passwords committed to git, Tempo S3 credentials relying on
instance-profile IAM — are tracked in
[`argocd/README.md`](argocd/README.md#known-gaps).

**Before running this anywhere beyond a dev cluster:**
1. Replace every `changeme`/hardcoded password (`services/postgresql/values.yaml`,
   `services/fastapi-app/values.yaml`, `platform/values/spoke/kube-prometheus-stack.yaml`)
   with values pulled from the `ClusterSecretStore` that's already wired up
   for ArgoCD's own cluster secrets — don't commit real credentials.
2. Put auth in front of the Prometheus and Alertmanager ingresses; only
   Grafana currently has a login.
3. Confirm Tempo's S3 access is actually coming from the EC2 instance
   profile as assumed (see `argocd/spokes/infra/30-tempo.yaml`).