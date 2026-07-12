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
├── clusters/                 # ONE find-based ExternalSecret, not per-spoke.
│   └── clusters-find.yaml     #   Discovers every "argocd-clusters/*" key in
│                               #   AWS Secrets Manager automatically — no
│                               #   git commit needed to register a spoke.
│
└── bootstrap/
    ├── README.md              # gaps: capture-versions.sh, spoke registration script
    └── capture-versions.sh    # (carry over from your existing repo, unchanged)
```

## How a spoke gets infra/workloads

Registration is **AWS-only** — no git commit is needed to onboard or
decommission a spoke, because `clusters/clusters-find.yaml` uses ESO's
`dataFrom.find` to discover every matching secret automatically.

1. You (or an onboarding script) create a ServiceAccount + token on the new
   spoke cluster and write `{name, server, token, caData}` into AWS Secrets
   Manager at key `argocd-clusters/<cluster-name>` — see
   `bootstrap/README.md`. That's the entire onboarding step.
2. On its next refresh (`refreshInterval: 5m`), the single
   `argocd-spoke-clusters` ExternalSecret re-evaluates the
   `argocd-clusters/` prefix, finds the new key, and ESO's
   `ClusterSecretStore` materializes a new `argocd`-namespace Secret for it
   — labeled `argocd.argoproj.io/secret-type: cluster` + `role: spoke`.
3. ArgoCD recognizes that Secret as a registered cluster. Every
   ApplicationSet under `spokes/infra/` and `spokes/workloads/` has a
   `clusters` generator matching `role: spoke`, so it generates
   `<release>-<cluster-name>` Applications targeting that spoke, honoring
   the same `sync-wave` ordering (`-1` → `50`) as before.
4. Deleting the AWS Secrets Manager entry removes the cluster Secret on
   the next refresh and — because the ApplicationSets use the cluster
   generator — ArgoCD cascades and removes every generated Application for
   that spoke too. Cilium's ApplicationSet keeps `prune: false` per-spoke
   for the same reason it always did: don't let automation rip out a live
   CNI.

If you'd rather have a git-reviewable audit trail of which spokes are
registered (e.g. for compliance), swap `clusters-find.yaml` for one
`ExternalSecret` file per spoke instead — the trade-off is an extra PR per
onboarding/offboarding in exchange for that history living in git rather
than only in AWS/CloudTrail.

## Why three separate root Applications instead of one

- `root-hub` changes rarely and only affects the hub's own control plane.
- `root-spokes` changes when infra/workload charts or versions change —
  fleet-wide, but the *set of clusters* affected doesn't change here.
- `root-clusters` barely changes at all now — it just keeps the single
  find-based `ExternalSecret` (and its `ClusterSecretStore` reference)
  under git management. Actual spoke add/remove events happen purely in AWS
  Secrets Manager and never touch this path.

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
  `kubectl` + `aws secretsmanager` process (no git steps required, since
  `clusters-find.yaml` discovers it automatically).
- **`dataFrom.find` cost/rate-limit at scale**: at large spoke counts, a 5m
  refresh interval means ESO issues a `find`-style listing call against
  Secrets Manager every 5 minutes regardless of whether anything changed.
  Fine for tens of spokes; worth revisiting (e.g. longer interval, or a
  push-based `PushSecret`/webhook trigger instead) if the fleet grows much
  larger.
- **Hub → spoke network reachability** must be solved per your topology
  (VPC peering, public NLB per spoke API server, etc.) — nothing in this
  repo provisions that.
- **`prometheus-operator-crds`** still isn't tracked as its own
  Application/ApplicationSet anywhere — same gap as the single-cluster
  layout, now needed on every spoke before `kube-prometheus-stack` can
  install there.
