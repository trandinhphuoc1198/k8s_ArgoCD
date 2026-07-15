# k8s_ArgoCD

GitOps-managed Kubernetes platform: a hub/spoke ArgoCD setup that deploys a
shared platform layer (CNI, ingress, observability, autoscaling, database
operator) plus application workloads (`fastapi-app`, `postgresql`) onto any
number of registered spoke clusters.

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
│   ├── root-apps/         # root-hub.yaml, root-spokes.yaml, root-clusters.yaml — apply once, by hand
│   ├── projects/          # AppProjects: platform-hub, platform-infra, platform-apps
│   ├── hub/                # Applications targeting the hub cluster itself.
│   │                       #   Sources values from platform/values/hub/ (hub-only settings) and,
│   │                       #   where hub and spoke intentionally share config (e.g. ingress-nginx),
│   │                       #   from platform/values/spoke/ — never inlined in the manifest.
│   ├── spokes/              # ApplicationSets fanned out to every registered spoke
│   │   ├── infra/            # 00 → 30: CNI, storage, ingress, observability, operators
│   │   └── workloads/        # 40 → 50: postgresql, fastapi-app
│   └── bootstrap/           # register-spoke.sh / deregister-spoke.sh, capture-versions.sh
│
├── helmfile/            ← manual alternative to argocd/ (same wave ordering, same values/ files)
│   ├── helmfile.yaml
│   ├── charts/noop/
│   └── hooks/
│
├── platform/             ← shared infra manifests/values/charts, sourced by both argocd/ and helmfile/
│   ├── values/
│   │   ├── base/           # Values shared across EVERY tier for charts that run on both hub and
│   │   │                   #   spoke (currently cert-manager, ingress-nginx). Every consumer layers
│   │   │                   #   its own tier file on top via a second helm.valueFiles entry.
│   │   ├── hub/            # Tier overrides for argocd/hub/*.yaml. Hub-only charts (e.g. argocd.yaml)
│   │   │                   #   live here with no base/ counterpart; shared charts get an (often empty)
│   │   │                   #   override file layered on top of base/.
│   │   └── spoke/          # Tier overrides fanned out to every spoke by argocd/spokes/
│   │                       #   ApplicationSets and referenced directly by helmfile/helmfile.yaml.
│   ├── cert-manager/
│   ├── charts/otel/
│   ├── grafana-dashboards/
│   └── monitoring-configs/
│
├── services/             ← application Helm charts
│   ├── fastapi-app/
│   ├── postgresql/
│   └── _unreleased/       # Charts not wired into argocd/ or helmfile/ yet (e.g. ai-agent-backend).
│                          #   Not deployed by either path — move into services/ proper once wired up.
│
├── init.sh / init-helmfile.sh / tear-down.sh
└── LIMITATIONS.md
```

## Why `platform/values/` is split into `base/`, `hub/`, and `spoke/`

Every file under `platform/values/spoke/` is consumed by an `argocd/spokes/`
ApplicationSet (and mirrored 1:1 by `helmfile/helmfile.yaml`), so editing one
affects **every** registered spoke cluster. Every file under
`platform/values/hub/` is consumed by exactly one `argocd/hub/*.yaml`
Application targeting the hub only. Keeping them in separate directories
means the blast radius of a change is obvious from the file's path alone —
no need to check which Application references it.

Two charts — `cert-manager` and `ingress-nginx` — run on **both** the hub
and every spoke. Rather than have one tier's Application reach into the
other tier's directory (or fork a duplicate file per tier), these use a
**base + overlay** pattern:

- `platform/values/base/<chart>.yaml` holds the config shared by every tier.
- `platform/values/hub/<chart>.yaml` and `platform/values/spoke/<chart>.yaml`
  are that tier's override, layered on top via a second `helm.valueFiles`
  entry. Both are empty (`{}`) today since hub and spoke don't currently
  diverge for these charts — add keys to the tier file, never to `base/`,
  the moment they need to.

No Application ever lists a values file from a directory it doesn't own.

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
