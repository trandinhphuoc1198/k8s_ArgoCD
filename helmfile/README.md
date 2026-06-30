# Helmfile — Manual Cluster Deployment

Drop-in replacement for ArgoCD. Mirrors the sync-wave order exactly.

## Prerequisites

```bash
brew install helm helmfile        # macOS
helm plugin install https://github.com/databus23/helm-diff
```

## Assumed directory layout

```
repo-root/
├── helmfile/          ← this folder
│   ├── helmfile.yaml
│   ├── charts/raw-apply/
│   └── hooks/
├── platform/
│   ├── cert-manager/
│   ├── charts/otel/
│   ├── grafana-dashboards/
│   └── upstream-values/
└── services/
    ├── fastapi-app/
    └── postgresql/
```

## Commands

| Goal | Command |
|---|---|
| Deploy everything | `helmfile apply` |
| Dry-run diff | `helmfile diff` |
| Deploy one wave | `helmfile apply -l wave=00` |
| Deploy one release | `helmfile apply -l name=cilium` |
| Destroy a release | `helmfile destroy -l name=fastapi-app` |
| List releases | `helmfile list` |

## Wave order

| Wave | Releases |
|---|---|
| `00` | cilium ⚠️, aws-ebs-csi-driver, cluster-autoscaler, cert-manager |
| `10` | cert-manager-configs, cnpg, ingress-nginx, keda, metrics-server, opentelemetry-operator |
| `20` | kube-prometheus-stack, otel |
| `30` | loki, tempo, grafana-dashboards |
| `40` | postgresql |
| `50` | fastapi-app |

## ⚠️ Cilium warning

`helmfile destroy` (or `helmfile apply` with pruning) **must never target the
`cilium` release on a live cluster**. Removing Cilium destroys the CNI and
takes down cluster networking. This mirrors the `prune: false` flag set in
`argocd/apps/infra/00-cilium.yaml`.

## cert-manager-configs

This release wraps the raw `platform/cert-manager/cert-manager-config.yaml`
manifests (Issuer, Certificate, ClusterIssuer) in a thin Helm chart
(`charts/raw-apply`) so they participate in helmfile's `needs` ordering.

## grafana-dashboards

The Grafana dashboard ConfigMaps have no Helm chart. The
`hooks/grafana-dashboards.sh` script runs a `kubectl apply` as a presync hook,
replicating what ArgoCD's directory-source Application does.
