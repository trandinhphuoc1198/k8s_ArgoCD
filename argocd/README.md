# ArgoCD for this cluster

This turns the manual `deploy.sh` flow into GitOps. Every Helm release that
script installed is now an Argo CD `Application`, ordered with sync-waves to
respect the same dependencies `deploy.sh` respected by running things in
sequence (CRDs before CRs, operators before the resources that use them).

ArgoCD manages **itself** the same way — a vanilla install gets you a running
controller, and from then on `argocd/apps/hub/00-argocd.yaml` is the single
source of truth for ArgoCD's own configuration (ingress, resource sizing,
insecure mode, etc.), synced by ArgoCD like any other Application.

```
argocd/
  bootstrap/
    argocd-values.yaml       # historical reference — no longer applied by hand,
                              # superseded by platform/upstream-values/argocd-values.yaml
    capture-versions.sh      # still used to pin floating chart versions before adoption
  projects/
    platform-infra.yaml      # AppProject — cluster infra, broad cluster-scope perms
    platform-apps.yaml       # AppProject — fastapi-app + postgresql, no cluster-scope perms
  root-app.yaml               # the "app of apps" — apply once, by hand
  apps/
    hub/                     # Applications whose destination is the HUB cluster
      00-argocd.yaml          # ArgoCD manages its own Helm release
    infra/                   # infrastructure layer — lower sync-wave, cluster-wide deps
      00-*.yaml
      01-*.yaml
      10-*.yaml
      20-*.yaml
      30-*.yaml
    workloads/                # application layer — higher sync-wave, waits for infra
      40-postgresql.yaml
      50-fastapi-app.yaml
```

## Why two projects

`platform-infra` covers everything with high blast radius and low change
frequency — CNI, storage, ingress, the observability stack, the operators
(KEDA, CNPG, OTel), and ArgoCD itself. It needs broad permission to create
cluster-scoped resources (CRDs, StorageClasses, ClusterRoles) because that's
literally what these charts do, and its destinations are scoped to the
system namespaces that own those resources, plus `argocd` (where `root-app`
creates the child Applications, and where ArgoCD's own Helm release lives).

`platform-apps` covers `fastapi-app` and `postgresql` — low blast radius,
changes on every deploy. Its destinations are scoped to `fastapi` and `db`
only, its `sourceRepos` only includes this git repo (no external Helm chart
repos — both charts are local), and it has **no** `clusterResourceWhitelist`
at all, so even a misconfigured chart change here can't accidentally create
a `ClusterRole` or a CRD. `postgresql` sits in `platform-apps` rather than
`platform-infra` because it's the app's database, not shared cluster
infrastructure — even though it depends on the CNPG operator that
`platform-infra` owns.

## Sync wave map

| Wave | Application | Needs |
|---|---|---|
| `-1` | `argocd` (hub) | — (vanilla install already running; this app reconfigures it) |
| `-1` | `cilium` | — (already running; this just takes over management) |
| `-1` | `aws-cloud-controller-manager` | — |
| `01` | `aws-ebs-csi-driver` | — (provides the `ebs-csi` StorageClass) |
| `01` | `cert-manager` | — |
| `01` | `cluster-autoscaler` | — |
| `10` | `cert-manager-configs` | wave 01 `cert-manager` (webhook ready) |
| `10` | `cnpg-operator` | — (provides Cluster/Pooler CRDs) |
| `10` | `ingress-nginx` | — |
| `10` | `keda` | — (provides ScaledObject CRD) |
| `10` | `metrics-server` | — |
| `10` | `opentelemetry-operator` | — (provides OTel CRDs) |
| `20` | `kube-prometheus-stack` | wave 01 `ebs-csi` StorageClass |
| `20` | `otel-collectors` | wave 10 OTel CRDs |
| `30` | `grafana-dashboards` | wave 20 Grafana sidecar |
| `30` | `loki` | observability namespace |
| `30` | `tempo` | observability namespace, wave 01 `ebs-csi` StorageClass |
| `40` | `postgresql` | wave 10 CNPG CRDs |
| `50` | `fastapi-app` | ingress-nginx, keda, otel, postgresql (all prior waves) |

> **Gap to close:** `prometheus-operator-crds` (the CRDs `kube-prometheus-stack`
> depends on) isn't tracked as an Application anywhere in this repo yet — it
> was previously installed imperatively in `init.sh` Step 1.1, which you're
> retiring. Add an Application for it at wave `-1` or `01` before relying on
> the vanilla-install flow end to end, or `kube-prometheus-stack` will fail
> to find its CRDs on a truly from-scratch cluster.

## Before you touch anything: pin the floating chart versions

Several charts (`aws-ebs-csi-driver`, `ingress-nginx`, `kube-prometheus-stack`,
`keda`, `cnpg`/`cloudnative-pg`) were historically installed by `deploy.sh`
**without** a `--version` flag, so whatever was "latest" the day someone ran
it is what's running now. Argo CD needs an explicit `targetRevision` for
each — there's no "latest" option for a GitOps source of truth. If you're
adopting an existing cluster (not a from-scratch one), run
`./argocd/bootstrap/capture-versions.sh` first and make sure every
`targetRevision` in `argocd/apps/` matches `helm list -A` before applying
`root-app.yaml` — your sync policy is **auto-sync + self-heal**, so a wrong
guess means an unplanned upgrade on adoption day, not a diff you get to
review first.

## Bootstrap order

1. **Install a vanilla ArgoCD** — no custom values, defaults only:
   ```bash
   helm repo add argo https://argoproj.github.io/argo-helm
   helm repo update
   helm install argocd argo/argo-cd \
     --namespace argocd --create-namespace \
     --wait
   ```
   This is intentionally minimal. Ingress, resource sizing, insecure mode,
   and everything else in `platform/upstream-values/argocd-values.yaml` gets
   applied in the next step — by ArgoCD, to itself.

2. **Apply the AppProjects and root Application**:
   ```bash
   kubectl apply -f argocd/projects/
   kubectl apply -f argocd/root-app.yaml
   ```

3. **Sync ArgoCD's own Application manually the first time.** Unlike the
   other wave-`-1` apps (Cilium, aws-ccm), this one is not a no-op adoption —
   it's a real diff from vanilla defaults to the full config. Watch it land
   before trusting automation:
   ```bash
   argocd app diff argocd
   argocd app sync argocd
   kubectl get pods -n argocd -w
   ```
   Once `argocd-server`, `argocd-repo-server`, and
   `argocd-application-controller` are healthy under the new config,
   everything else proceeds automatically.

4. **Watch the rest converge**:
   ```bash
   kubectl get applications -n argocd -w
   ```
   or watch it in the UI. Each Application shows Synced/Healthy once its
   wave is done and the next wave starts.

## What full GitOps + auto-sync + self-heal means day to day

- Any `kubectl edit` / `helm upgrade` run by hand against a managed
  resource — including ArgoCD itself — gets reverted within minutes. Git is
  the only place changes stick. Use `kubectl apply -f argocd/...` style
  changes via git, not imperative kubectl, from now on.
- Deleting an Application file from `argocd/apps/` and pushing that commit
  will **prune** (delete) everything that Application owns, except Cilium,
  which has `prune: false` set deliberately — accidentally deleting your
  CNI's Application would take the whole cluster's pod networking down with
  it. Remove that Application manually and deliberately if you ever need to.
- `deploy.sh` / `tear-down.sh` / `init.sh` are now redundant for anything
  under Argo CD management — don't run them against this cluster again once
  `root-app.yaml` is applied, since they'll fight with Argo CD's self-heal.

## Known gaps / things worth a second look

- **ArgoCD self-management is a real (non-no-op) first sync now.** Since the
  bootstrap script that used to apply the full values file directly is
  retired, the very first sync of `apps/hub/00-argocd.yaml` reconfigures a
  live vanilla install — see Step 3 above. `prune: true` on ArgoCD's own
  Helm release also means its bundled CRDs (`applications.argoproj.io`,
  `appprojects.argoproj.io`, `applicationsets.argoproj.io`) are technically
  prunable; a future chart restructuring that renames them could cascade-
  delete every Application/AppProject in the cluster. Worth adding
  `PrunePropagationPolicy=foreground` and/or a `Prune=false` sync-option on
  the CRDs specifically before this leaves a dev cluster.
- **`prometheus-operator-crds` has no Application yet** — see the callout in
  the sync-wave table above.
- **Secrets in git**: `services/postgresql/values.yaml` and
  `services/fastapi-app/values.yaml` both ship placeholder passwords
  (`changeme`) committed in plaintext, and
  `platform/upstream-values/kube-prometheus-stack-values.yaml` has a
  plaintext Grafana admin password. Worth moving these to Sealed Secrets or
  External Secrets Operator before this goes beyond a dev cluster.
- **Tempo S3 credentials**: `platform/upstream-values/tempo-values.yaml`
  references a `tempo-s3-credentials` Secret in its comments, but the
  `extraEnvFrom` blocks that would consume it are commented out, and no
  chart in this repo creates that Secret. This implies Tempo/Loki are
  getting S3 access from the EC2 instance profile's IAM role rather than a
  k8s Secret — worth confirming that's intentional before relying on it.
- **NodePort collision check**: if ArgoCD's ingress and ingress-nginx's
  NodePorts (30080/30443) both land in Cilium's configured
  `30000-32767` range, double check for collisions before applying,
  especially once ArgoCD's own ingress is live from wave `-1`.