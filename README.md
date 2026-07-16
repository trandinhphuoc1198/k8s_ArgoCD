# ArgoCD — Hub/Spoke Multi-Cluster Layout

This directory runs a **hub/spoke** topology. ArgoCD itself lives on the
hub cluster; `platform/` infra and `services/` workloads are deployed onto
any number of **spoke** clusters, registered dynamically via External
Secrets Operator (ESO) pulling from AWS Secrets Manager.

```
argocd/
├── root-apps/
│   ├── root-hub.yaml        # App-of-apps → argocd/hub      (hub only)
│   ├── root-spokes.yaml     # App-of-apps → argocd/spokes   (ApplicationSets, fan out to spokes)
│   └── root-clusters.yaml   # App-of-apps → argocd/clusters (spoke registration ExternalSecrets)
│
├── projects/
│   ├── platform-hub.yaml    # AppProject — ArgoCD's own mgmt + ESO. server pinned to the hub only.
│   ├── platform-infra.yaml  # AppProject — spoke infra. server: "*", namespace-scoped.
│   └── platform-apps.yaml   # AppProject — spoke workloads. server: "*", namespace-scoped.
│
├── hub/                      # Applications. destination is ALWAYS the hub (kubernetes.default.svc).
│   ├── 00-argocd.yaml           # values: hub/argocd.yaml (hub-only, no base/ counterpart)
│   ├── 01-external-secrets.yaml
│   ├── 01-cert-manager.yaml     # values: base/cert-manager.yaml + hub/cert-manager.yaml (overlay)
│   ├── 02-external-secrets-config.yaml
│   ├── 02-cert-manager-configs.yaml
│   └── 02-ingress-nginx.yaml    # values: base/ingress-nginx.yaml + hub/ingress-nginx.yaml (overlay)
│
├── spokes/                   # ApplicationSets (cluster generator, selector cluster-role=workload).
│   ├── infra/                #   one Application PER SPOKE PER FILE, auto-created/removed
│   │   ├── 00-cilium.yaml               # never prune=true — pruning Cilium loses the CNI
│   │   ├── 00-aws-ccm.yaml
│   │   ├── 01-cluster-autoscaler.yaml
│   │   ├── 01-aws-ebs-csi-driver.yaml
│   │   ├── 01-cert-manager.yaml
│   │   ├── 10-ingress-nginx.yaml
│   │   ├── 10-metrics-server.yaml
│   │   ├── 10-cnpg-operator.yaml
│   │   ├── 10-opentelemetry-operator.yaml
│   │   ├── 10-keda.yaml
│   │   ├── 10-kube-prometheus-stack.yaml
│   │   ├── 10-cert-manager-configs.yaml
│   │   ├── 20-otel-collectors.yaml
│   │   ├── 20-cilium-servicemonitors.yaml
│   │   ├── 30-grafana-dashboards.yaml
│   │   ├── 30-loki.yaml
│   │   └── 30-tempo.yaml
│   └── workloads/
│       ├── 40-postgresql.yaml
│       └── 50-fastapi-app.yaml
│
├── clusters/                 # One ExternalSecret per registered spoke.
│   └── workload.yaml           # e.g. spoke-dev — adding a file here = onboarding a spoke
│
└── bootstrap/
    ├── README.md              # register-spoke.sh / deregister-spoke.sh usage
    └── capture-versions.sh
```

## Sync-wave ordering

Waves encode real dependencies — don't reorder them without checking what
depends on what:

| Wave | Components | Depends on |
|---|---|---|
| `00` | Cilium, AWS CCM | node bootstrap only |
| `01` | Cluster Autoscaler, EBS CSI driver, cert-manager | Cilium networking |
| `10` | ingress-nginx, metrics-server, CNPG operator, OTel Operator, KEDA, kube-prometheus-stack, cert-manager configs | EBS CSI (`ebs-csi` StorageClass), cert-manager CRDs |
| `20` | OTel collectors, Cilium/Hubble ServiceMonitors | OTel Operator CRDs (wave 10), `prometheus-operator-crds` |
| `30` | Grafana dashboards, Loki, Tempo | `monitoring` namespace + Grafana sidecar (wave 10) |
| `40` | postgresql | CNPG operator CRDs (wave 10) |
| `50` | fastapi-app | ingress-nginx, KEDA, OTel collectors, postgresql poolers, ServiceMonitor CRD |

## How a spoke gets infra/workloads

1. Create a ServiceAccount + token on the new spoke cluster and write
   `{name, server, token, caData}` into AWS Secrets Manager at
   `argocd-clusters/<cluster-name>` — see `bootstrap/README.md`.
2. Add `argocd/clusters/<cluster-name>.yaml` (copy the existing one,
   rename) and push.
3. `root-clusters` syncs it → ESO's `ClusterSecretStore` resolves the AWS
   secret → materializes an `argocd`-namespace Secret labeled
   `argocd.argoproj.io/secret-type: cluster` + `cluster-role: workload`.
4. ArgoCD recognizes that Secret as a registered cluster. Every
   ApplicationSet under `spokes/infra/` and `spokes/workloads/` has a
   `clusters` generator matching `cluster-role: workload`, so it
   immediately generates `<release>-<cluster-name>` Applications targeting
   that spoke, honoring the sync-wave ordering above.
5. Deleting the cluster's file under `argocd/clusters/` removes the
   cluster Secret and cascades to remove every generated Application for
   that spoke — except Cilium, which keeps `prune: false` per-spoke so
   automation can never rip out a live CNI.

## Bootstrap order (fresh hub)

1. `init.sh` — installs Cilium + Cluster Autoscaler by hand on the hub
   node(s), installs ArgoCD via Helm, applies `argocd/projects/`, then
   applies `argocd/root-apps/root-hub.yaml`.
2. Apply `argocd/root-apps/root-spokes.yaml` and
   `argocd/root-apps/root-clusters.yaml` once, by hand — these are the
   only manifests in this repo not managed by another Application.
3. Register each spoke per "How a spoke gets infra/workloads" above.
   ArgoCD fans out every `spokes/` ApplicationSet automatically from there.

## Why three separate root Applications instead of one

- `root-hub` changes rarely and only affects the hub's own control plane.
- `root-spokes` changes when infra/workload charts or versions change —
  fleet-wide, but the *set of clusters* affected doesn't change here.
- `root-clusters` changes every time a spoke is added/removed — highest
  frequency, narrowest blast radius (one cluster's registration, not the
  chart definitions).

Keeping them separate means `git log` on each path tells you exactly what
kind of change happened, and a mistake in one can't accidentally prune the
other two.

## AppProject boundaries

- **`platform-hub`** — `destinations` pinned to
  `https://kubernetes.default.svc` only. Nothing here should ever be
  templated onto a spoke; this exists specifically so a misconfigured
  `clusters` generator selector elsewhere can never match ArgoCD's own
  management resources.
- **`platform-infra`** / **`platform-apps`** — `destinations` use
  `server: "*"` because these Applications are generated per-spoke by
  ApplicationSets; the real boundary is the namespace whitelist, not the
  server. `platform-apps` is deliberately barred from creating anything
  cluster-scoped (only `Namespace` is whitelisted); `platform-infra` is
  wide open because it legitimately owns CRDs, StorageClasses, and
  ClusterRoles.

## Hub vs. spoke values — the `base/` + tier overlay pattern

`platform/values/` has three directories:

- **`platform/values/hub/`** — tier overrides consumed only by
  `argocd/hub/*.yaml`. `argocd.yaml` (ArgoCD's own Helm values) is
  hub-only and has no `base/` counterpart, since nothing else ever runs
  ArgoCD itself.
- **`platform/values/spoke/`** — tier overrides consumed by
  `argocd/spokes/infra/*.yaml` ApplicationSets (fleet-wide, one file →
  every spoke) and mirrored by `helmfile/helmfile.yaml` for local/manual
  deploys.
- **`platform/values/base/`** — config shared across **every** tier, for
  charts that intentionally run identically on both hub and spoke. Today
  that's `cert-manager` and `ingress-nginx`.

For a base-backed chart, every consuming Application/ApplicationSet lists
**two** `helm.valueFiles` entries, base first so the tier file can override
it:

```yaml
helm:
  valueFiles:
    - $values/platform/values/base/cert-manager.yaml
    - $values/platform/values/hub/cert-manager.yaml    # or spoke/, depending on tier
```

`platform/values/hub/cert-manager.yaml` and
`platform/values/spoke/cert-manager.yaml` (same for `ingress-nginx.yaml`)
are both empty (`{}`) today — hub and spoke don't currently need different
settings for either chart. Add keys to the relevant tier file only when
they do; `base/*.yaml` is never edited to special-case one tier, and no
Application lists a values file from a directory it doesn't own.

One caveat worth knowing: `platform/values/base/ingress-nginx.yaml`
enables OTel tracing pointed at
`otel-collector-ds-collector.observability.svc`, which only exists on
spokes. On the hub this is harmless — nginx logs failed span exports but
keeps serving traffic — and can be turned off via a
`platform/values/hub/ingress-nginx.yaml` override if it ever gets noisy.

## Known gaps

- **Plaintext `changeme` passwords committed to git** —
  `services/postgresql/values.yaml` and `services/fastapi-app/values.yaml`
  both ship placeholder DB passwords in git, which are now the live source
  of truth for every registered spoke. The `ClusterSecretStore` this repo
  already uses for spoke-registration tokens
  (`platform/external-secrets-config/cluster-secret-store.yaml`) should be
  extended to these app/db secrets before this goes past a dev
  environment.
- **`prometheus-operator-crds` is not tracked as its own
  Application/ApplicationSet** — `kube-prometheus-stack` (wave 10) and
  every ServiceMonitor-emitting chart implicitly depend on those CRDs
  existing on the spoke, but nothing in `argocd/` installs them
  explicitly today.
- **Floating chart versions** — most `targetRevision` pins are exact, but
  double-check any chart before upgrading a fleet-wide spoke value file;
  a bad `values/spoke/*.yaml` change for an externally-sourced chart gets
  no CI validation before ArgoCD applies it (CI only renders the three
  local charts — see the root `README.md#ci`).
- **Tempo S3 credentials rely on instance-profile IAM**, not a Kubernetes
  Secret — the `extraEnvFrom` blocks referencing `tempo-s3-credentials` in
  `platform/values/spoke/tempo.yaml` are commented out and no chart in
  this repo creates that Secret. Confirm this is actually working on a
  live spoke node before depending on it.
- **No automated spoke-registration script yet** — see
  `bootstrap/README.md`. Until that exists, onboarding a spoke is a manual
  `kubectl` + `aws secretsmanager` process before the git-side steps
  described above.
- **Hub → spoke network reachability** must be solved per your topology
  (VPC peering, a public NLB per spoke API server, etc.) — nothing in
  this repo provisions that.
- **No auth in front of Prometheus/Alertmanager** — the ingresses in
  `platform/values/spoke/kube-prometheus-stack.yaml` expose both with TLS
  but no authentication; only Grafana has a login today.
- **Hub `ingress-nginx` inherits OTel tracing config** from the shared
  `platform/values/spoke/ingress-nginx.yaml` file even though the hub has
  no OTel collector to send those traces to. Harmless today but worth
  revisiting if the failed-export logs get noisy.