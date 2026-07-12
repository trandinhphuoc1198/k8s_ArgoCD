# ArgoCD — Hub/Spoke Multi-Cluster Layout

This repo runs a **hub/spoke** topology. ArgoCD itself lives on the hub
cluster; `platform/` infra and `services/` workloads are deployed onto any
number of **spoke** clusters, registered dynamically via External Secrets
Operator (ESO) pulling from AWS Secrets Manager.

```
argocd/
├── root-apps/
│   ├── root-hub.yaml         # App-of-apps → argocd/hub    (hub only)
│   └── root-spokes.yaml      # App-of-apps → argocd/spokes (ApplicationSets, fan out to spokes)
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
└── bootstrap/
    ├── README.md                       # spoke registration design + gaps
    ├── capture-versions.sh             # (carry over from your existing repo, unchanged)
    ├── external-secret-template.yaml   # per-spoke ExternalSecret, applied by script (not git)
    ├── register-spoke.sh               # onboard a spoke — no git commit involved
    └── deregister-spoke.sh             # offboard a spoke
```

## How a spoke gets infra/workloads

Registration is a **script**, not GitOps — `bootstrap/register-spoke.sh`
applies the spoke's `ExternalSecret` directly to the hub's live API, so
onboarding never requires a git commit.

1. Run `bootstrap/register-spoke.sh <cluster-name> <spoke-kube-context>
   [role] [env]`. It creates a ServiceAccount on the spoke, writes
   `{name, server, token, caData, role, env}` to AWS Secrets Manager at
   `argocd-clusters/<cluster-name>`, then applies the rendered
   `ExternalSecret` to the hub.
2. On its next refresh (`refreshInterval: 5m`), ESO's `ClusterSecretStore`
   resolves that AWS secret and materializes an `argocd`-namespace `Secret`
   for it — labeled `argocd.argoproj.io/secret-type: cluster`, plus
   `role`/`env` read **dynamically from the secret payload itself** (Go
   template `{{ .role }}` / `{{ .env }}`), not hardcoded anywhere in the
   template. The spoke's own provisioning data decides its labels.
3. ArgoCD recognizes that `Secret` as a registered cluster. Every
   ApplicationSet under `spokes/infra/` and `spokes/workloads/` has a
   `clusters` generator matching `role: spoke`, so it generates
   `<release>-<cluster-name>` Applications targeting that spoke, honoring
   the same `sync-wave` ordering (`-1` → `50`) as before.
4. `bootstrap/deregister-spoke.sh <cluster-name>` reverses this: deletes
   the `ExternalSecret` + generated `Secret` on the hub (cascading removal
   of every generated Application, Cilium excluded per its
   `prune: false`), then deletes the Secrets Manager entry. Run it before
   tearing down the spoke's infrastructure.

**Why not a single `find`-based `ExternalSecret` instead of a script:** ESO's
`dataFrom.find` merges every matched AWS secret into keys on *one*
Kubernetes `Secret`, not into N separate `Secret` objects — but ArgoCD
needs each spoke as its own `Secret`. That ruled it out; `register-spoke.sh`
applying a per-spoke `ExternalSecret` directly (bypassing git, not bypassing
"one Secret per cluster") is the actual fix. See `bootstrap/README.md` for
the full rationale.

## Why two separate root Applications instead of one

- `root-hub` changes rarely and only affects the hub's own control plane
  (ArgoCD itself, ESO, the `ClusterSecretStore`).
- `root-spokes` changes when infra/workload charts or versions change —
  fleet-wide, but which *clusters* are affected is driven entirely by
  cluster registration (`bootstrap/register-spoke.sh`), not by anything
  under `root-spokes`'s own path.

Spoke registration itself isn't a third root Application — see "How a spoke
gets infra/workloads" above for why that's a script against the hub's live
API rather than a git-synced resource.

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

## Known gaps / new

- Everything previously listed in the single-cluster README (floating chart
  versions, plaintext `changeme` passwords, Tempo S3 credentials via
  instance-profile IAM) still applies — now multiplied across every spoke.
- **`register-spoke.sh` mints a 10-year token and grants cluster-admin on
  the spoke** — reasonable for a dev fleet, worth tightening (shorter TTL +
  rotation, or a narrower ClusterRole if ArgoCD's actual footprint ends up
  smaller than "everything") before production.
- **Hub → spoke network reachability** must be solved per your topology
  (VPC peering, public NLB per spoke API server, etc.) — the script doesn't
  verify this, and nothing in this repo provisions it.
- **`prometheus-operator-crds`** still isn't tracked as its own
  Application/ApplicationSet anywhere — same gap as the single-cluster
  layout, now needed on every spoke before `kube-prometheus-stack` can
  install there.
