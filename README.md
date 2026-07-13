# k8s_ArgoCD

GitOps-managed Kubernetes platform: a hub/spoke ArgoCD setup that deploys a
shared platform layer (CNI, ingress, observability, autoscaling, database
operator) plus two application workloads (`fastapi-app`, `postgresql`) onto
any number of registered spoke clusters.

There are two independent ways to stand this cluster up from the manifests
in this repo — pick one, don't mix them on the same cluster:

| Path | Use when |
|---|---|
| **`argocd/`** (GitOps, hub/spoke) | Steady-state / multi-cluster. Auto-sync + self-heal. See [`argocd/README.md`](argocd/README.md). |
| **`helmfile/`** (manual, single cluster) | Local dev, one-off environments, or debugging without ArgoCD in the loop. See [`helmfile/README.md`](helmfile/README.md). |

## Repo layout

```
repo-root/
├── argocd/              ← GitOps source of truth (see argocd/README.md)
│   ├── root-apps/         # root-hub.yaml, root-spokes.yaml — apply once, by hand
│   ├── projects/          # AppProjects: platform-hub, platform-infra, platform-apps
│   ├── hub/                # Applications targeting the hub cluster itself
│   ├── spokes/              # ApplicationSets fanned out to every registered spoke
│   │   ├── infra/            # 00 → 30: CNI, storage, ingress, observability, operators
│   │   └── workloads/        # 40 → 50: postgresql, fastapi-app
│   └── bootstrap/           # register-spoke.sh / deregister-spoke.sh, capture-versions.sh
│
├── helmfile/            ← manual alternative to argocd/ (same wave ordering)
│   ├── helmfile.yaml
│   ├── charts/raw-apply/
│   └── hooks/
│
├── platform/             ← shared infra manifests/values/charts, sourced by both
│   ├── cert-manager/
│   ├── charts/otel/
│   ├── grafana-dashboards/
│   ├── monitoring-configs/
│   └── upstream-values/
│
├── services/             ← application Helm charts
│   ├── fastapi-app/
│   ├── ai-agent-backend/
│   └── postgresql/
│
├── init.sh / init-helmfile.sh / tear-down.sh
└── LIMITATIONS.md
```

## Which init script does what

- `init.sh` — bootstraps Cilium + Cluster Autoscaler by hand, installs ArgoCD,
  then applies `argocd/root-apps/`. Legacy single-cluster ArgoCD bootstrap;
  the current hub/spoke bootstrap procedure is documented in
  [`argocd/README.md`](argocd/README.md#bootstrap-order) and uses
  `argocd/bootstrap/register-spoke.sh` to onboard each spoke.
- `init-helmfile.sh` — installs `helm`/`helmfile` if missing, then runs
  `helmfile apply` against whatever cluster your kubeconfig points at. No
  ArgoCD involved at all.
- `tear-down.sh` — aggressive, non-GitOps purge script (deletes ArgoCD
  Applications, force-deletes workloads/PVCs/namespaces). Only for
  scrapping a cluster entirely; do **not** run it against a cluster under
  active ArgoCD self-heal — see the warning in `argocd/README.md`.

## Known gaps

See [`LIMITATIONS.md`](LIMITATIONS.md) for the platform-level list (Cilium
VXLAN mode, no NetworkPolicies yet, no service mesh, etc). ArgoCD/GitOps-
specific gaps (floating chart versions, `prometheus-operator-crds` not
tracked as its own Application, plaintext `changeme` passwords, Tempo S3
credentials relying on instance-profile IAM) are tracked in
[`argocd/README.md`](argocd/README.md#known-gaps--new).