# ArgoCD — Hub/Spoke Multi-Cluster Layout

This repo runs a **hub/spoke** topology. ArgoCD itself lives on the hub
cluster; `platform/` infra and `services/` workloads are deployed onto any
number of **spoke** clusters, registered dynamically via External Secrets
Operator (ESO) pulling from AWS Secrets Manager.

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
│   ├── 00-argocd.yaml
│   ├── 00-external-secrets.yaml
│   ├── 01-external-secrets-config.yaml
│   └── 01-external-secrets-config/
│       └── cluster-secret-store.yaml
│
├── spokes/                   # ApplicationSets (cluster generator, selector role=spoke).
│   ├── infra/                #   one Application PER SPOKE PER FILE, auto-created/removed
│   │   ├── 00-cilium.yaml
│   │   ├── 00-aws-ccm.yaml
│   │   ├── 01-*.yaml
│   │   ├── 10-*.yaml
│   │   ├── 20-*.yaml
│   │   ├── 25-*.yaml
│   │   └── 30-*.yaml
│   └── workloads/
│       ├── 40-postgresql.yaml
│       └── 50-fastapi-app.yaml
│
├── clusters/                 # One ExternalSecret per registered spoke.
│   ├── spoke-dev.yaml         #   Adding a file here = onboarding a spoke.
│   └── spoke-prod.yaml
│
└── bootstrap/
    ├── README.md              # gaps: capture-versions.sh, spoke registration script
    └── capture-versions.sh    # (carry over from your existing repo, unchanged)
```

## How a spoke gets infra/workloads

1. You (or an onboarding script) create a ServiceAccount + token on the new
   spoke cluster and write `{name, server, token, caData}` into AWS Secrets
   Manager at `argocd-clusters/<cluster-name>` — see `bootstrap/README.md`.
2. You add `argocd/clusters/<cluster-name>.yaml` (copy `spoke-dev.yaml`,
   rename) and push.
3. `root-clusters` syncs it → ESO's `ClusterSecretStore` resolves the AWS
   secret → materializes an `argocd`-namespace Secret labeled
   `argocd.argoproj.io/secret-type: cluster` + `role: spoke`.
4. ArgoCD recognizes that Secret as a registered cluster. Every
   ApplicationSet under `spokes/infra/` and `spokes/workloads/` has a
   `clusters` generator matching `role: spoke`, so it immediately generates
   `<release>-<cluster-name>` Applications targeting that spoke, honoring
   the same `sync-wave` ordering (`-1` → `50`) as before.
5. Deleting the cluster's file under `argocd/clusters/` removes the cluster
   Secret and — because the ApplicationSets use the cluster generator —
   ArgoCD cascades and removes every generated Application for that spoke
   too. Cilium's ApplicationSet keeps `prune: false` per-spoke for the same
   reason it always did: don't let automation rip out a live CNI.

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

- **`platform-hub`**: `destinations` pinned to
  `https://kubernetes.default.svc` only. Nothing here should ever be
  templated onto a spoke — this project exists specifically so a
  misconfigured `clusters` generator selector elsewhere can never match
  ArgoCD's own management resources.
- **`platform-infra`** / **`platform-apps`**: `destinations` use
  `server: "*"` because these Applications are generated per-spoke by
  ApplicationSets — the real boundary is the namespace whitelist, same as
  before.

## Known gaps carried forward / new

- Everything previously listed in the single-cluster README (floating chart
  versions, plaintext `changeme` passwords, Tempo S3 credentials via
  instance-profile IAM) still applies — now multiplied across every spoke.
- **No automated spoke-registration script yet** — see
  `bootstrap/README.md`. Until that exists, onboarding a spoke is a manual
  `kubectl` + `aws secretsmanager` process before the git-side steps above.
- **Hub → spoke network reachability** must be solved per your topology
  (VPC peering, public NLB per spoke API server, etc.) — nothing in this
  repo provisions that.
- **`prometheus-operator-crds`** still isn't tracked as its own
  Application/ApplicationSet anywhere — same gap as the single-cluster
  layout, now needed on every spoke before `kube-prometheus-stack` can
  install there.
