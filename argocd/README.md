# ArgoCD for this cluster

This turns the manual `deploy.sh` flow into GitOps. Every Helm release that
script installs is now an Argo CD `Application`, ordered with sync-waves to
respect the same dependencies `deploy.sh` respects by running things in
sequence (CRDs before CRs, operators before the resources that use them).

```
argocd/
  bootstrap/             # one-time, manual — installs Argo CD itself
    argocd-values.yaml
    install-argocd.sh
    capture-versions.sh
  projects/
    platform-infra.yaml   # AppProject — cluster infra, broad cluster-scope perms
    platform-apps.yaml    # AppProject — fastapi-app + postgresql, no cluster-scope perms
  root-app.yaml            # the "app of apps" — apply once, by hand
  apps/
    infra/                 # infrastructure layer — lower sync-wave, cluster-wide deps
      00-*.yaml
      10-*.yaml
      20-kube-prometheus-stack.yaml
      20-otel-collectors.yaml
      30-*.yaml
    workloads/            # application layer — higher sync-wave, waits for infra
      20-postgresql.yaml
      40-fastapi-app.yaml
```

## Why two projects

`platform-infra` covers everything with high blast radius and low change
frequency — CNI, storage, ingress, the observability stack, the operators
(KEDA, CNPG, OTel). It needs broad permission to create cluster-scoped
resources (CRDs, StorageClasses, ClusterRoles) because that's literally what
these charts do, and its destinations are scoped to the system namespaces
that own those resources, plus `argocd` (where `root-app` creates the child
Applications).

`platform-apps` covers `fastapi-app` and `postgresql` — low blast radius,
changes on every deploy. Its destinations are scoped to `fastapi` and `db`
only, its `sourceRepos` only includes this git repo (no external Helm chart
repos — both charts are local), and it has **no** `clusterResourceWhitelist`
at all, so even a misconfigured chart change here can't accidentally create
a `ClusterRole` or a CRD. `postgresql` sits in `platform-apps` rather than
`platform-infra` because it's the app's database, not shared cluster
infrastructure — even though it depends on the CNPG operator that
`platform-infra` owns.

This also means: if you bring on a teammate or a second app later, they get
scoped access to `platform-apps` (once RBAC/SSO is wired up — see below) and
literally cannot touch `platform-infra`'s resources, by AppProject
definition, not just by convention.

## Sync wave map (mirrors deploy.sh's ordering)

| Wave | Application | Needs |
|---|---|---|
| 0 | `prometheus-operator-crds` | — |
| 0 | `cilium` | — (already running; this just takes over management) |
| 10 | `cluster-autoscaler` | — |
| 10 | `aws-ebs-csi-driver` | — (provides the `ebs-csi` StorageClass) |
| 10 | `ingress-nginx` | — |
| 10 | `opentelemetry-operator` | — (provides OTel CRDs) |
| 10 | `keda` | — (provides ScaledObject CRD) |
| 10 | `cnpg-operator` | — (provides Cluster/Pooler CRDs) |
| 20 | `kube-prometheus-stack` | wave 0 CRDs, wave 10 StorageClass |
| 20 | `otel-collectors` | wave 10 OTel CRDs |
| 40 | `postgresql` | wave 10 CNPG CRDs, after the infra layer |
| 30 | `tempo`, `loki` | observability namespace |
| 30 | `grafana-dashboards` | wave 20 Grafana sidecar |
| 50 | `fastapi-app` | ingress-nginx, keda, otel, postgresql, after infra completes |

`metrics-server` is skipped — it's commented out in your current `deploy.sh`
too, so this preserves the cluster's actual current state. Add an
Application for it later if you turn it back on.

## Before you touch anything: pin the floating chart versions

`deploy.sh` installs several charts (`aws-ebs-csi-driver`, `ingress-nginx`,
`kube-prometheus-stack`, `keda`, `cnpg`/`cloudnative-pg`,
`prometheus-operator-crds`) **without** a `--version` flag, so whatever was
"latest" the day someone ran it is what's running now. Argo CD needs an
explicit `targetRevision` for each — there's no "latest" option for a GitOps
source of truth.

Six files have a placeholder:

```
argocd/apps/00-prometheus-operator-crds.yaml
argocd/apps/10-aws-ebs-csi-driver.yaml
argocd/apps/10-ingress-nginx.yaml
argocd/apps/10-keda.yaml
argocd/apps/10-cnpg-operator.yaml
argocd/apps/20-kube-prometheus-stack.yaml
```

each with `targetRevision: "REPLACE_ME"`. **Run this against the live
cluster first**, before applying `root-app.yaml`:

```bash
./argocd/bootstrap/capture-versions.sh
```

Replace each `REPLACE_ME` with the version currently deployed. This matters
because your sync policy is **auto-sync + self-heal**: the moment
`root-app.yaml` is applied, Argo CD will try to converge the cluster to
whatever's in git, immediately. A wrong guess on `kube-prometheus-stack` or
`ingress-nginx` means an unplanned upgrade on adoption day, not a diff you
get to review first.

The other charts (`cilium`, `cluster-autoscaler`, `opentelemetry-operator`,
`tempo`, `loki`) are already pinned to match the explicit `--version` flags
in `deploy.sh` — verify those still match `helm list -A` output but they
shouldn't need edits.

## Bootstrap order

1. **Install Argo CD itself** (it can't manage its own installation):
   ```bash
   ./argocd/bootstrap/install-argocd.sh
   ```
   This prints the initial admin password and the UI is reachable at
   `http://<any-node-ip>:30180`.

2. **Capture and fill in chart versions** (see above) and commit that to git.

3. **Apply the AppProjects and root Application**:
   ```bash
   kubectl apply -f argocd/projects/
   kubectl apply -f argocd/root-app.yaml
   ```
   From here, everything under [argocd/apps/infra](argocd/apps/infra) and
   [argocd/apps/workloads](argocd/apps/workloads) is created and synced automatically,
   with the application layer ordered after the infrastructure layer via sync
   waves.

4. **Watch it converge**:
   ```bash
   kubectl get applications -n argocd -w
   ```
   or watch it in the UI. Each Application shows Synced/Healthy once its
   wave is done and the next wave starts.

## What full GitOps + auto-sync + self-heal means day to day

- Any `kubectl edit` / `helm upgrade` run by hand against a managed
  resource gets reverted within minutes — git is the only place changes
  stick. Use `kubectl apply -f argocd/...` style changes via git, not
  imperative kubectl, from now on.
- Deleting an Application file from `argocd/apps/` and pushing that commit
  will **prune** (delete) everything that Application owns, except Cilium,
  which has `prune: false` set deliberately — accidentally deleting your
  CNI's Application would take the whole cluster's pod networking down with
  it. Remove that Application manually and deliberately if you ever need to.
- `deploy.sh` / `tear-down.sh` are now redundant for anything under Argo CD
  management — don't run `deploy.sh` against this cluster again once
  `root-app.yaml` is applied, since it'll fight with Argo CD's self-heal.

## Known gaps / things worth a second look

- **Secrets in git**: `charts/postgresql/values.yaml` and
  `charts/fastapi-app/values.yaml` both ship placeholder passwords
  (`changeme`) committed in plaintext, and
  `k8s/helm/kube-prometheus-stack-values.yaml` has a plaintext Grafana
  admin password. Pre-existing in your repo, not introduced by this setup —
  but now that git is the literal live source of truth, it's worth moving
  these to something like Sealed Secrets or External Secrets Operator
  before this goes beyond a dev cluster.
- **Tempo S3 credentials**: `k8s/helm/tempo-values.yaml` references a
  `tempo-s3-credentials` Secret in its comments, but the `extraEnvFrom`
  blocks that would consume it are commented out, and no chart in this repo
  creates that Secret. This implies Tempo/Loki are getting S3 access from
  the EC2 instance profile's IAM role rather than a k8s Secret — worth
  confirming that's intentional before relying on it.
- **NodePort collision check**: Argo CD's NodePorts (30180/30543) were
  chosen to avoid colliding with ingress-nginx's (30080/30443), both inside
  Cilium's configured `30000-32767` range. If you've opened other fixed
  NodePorts elsewhere, double check before applying.
