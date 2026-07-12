# argocd/bootstrap/

## capture-versions.sh
Not included in this restructure — carry your existing
`argocd/bootstrap/capture-versions.sh` over unchanged from the current repo.
It isn't referenced by path from anything else here, so simply copying it
into this folder is a drop-in replacement.

## register-spoke.sh (new — you'll need to write this)
Nothing in this repo yet creates the AWS Secrets Manager entry that
`argocd/clusters/<name>.yaml`'s ExternalSecret reads from
(`argocd-clusters/<cluster-name>`). Before a new spoke file will resolve to
anything, something needs to, per spoke:

  1. Create a ServiceAccount + ClusterRoleBinding on the SPOKE cluster that
     ArgoCD (running on the hub) will authenticate as. ArgoCD needs broad
     permissions there (effectively cluster-admin), since it manages
     arbitrary resources across the infra/workloads ApplicationSets.
  2. Pull that ServiceAccount's token, the spoke's API server URL, and its
     CA certificate.
  3. Write those three values into AWS Secrets Manager at
     `argocd-clusters/<cluster-name>` as JSON:
       { "name": "<cluster-name>", "server": "https://...", "token": "...", "caData": "<base64 CA>" }
  4. Confirm hub -> spoke network reachability to that API server (VPC
     peering / routing / public NLB — whatever your topology requires).

That's it — no git step. `argocd/clusters/clusters-find.yaml` uses ESO's
`dataFrom.find` to discover every key under the `argocd-clusters/` prefix
on its own 5-minute refresh, so as soon as step 3 lands, the spoke is
registered and every `spokes/` ApplicationSet picks it up automatically.
Decommissioning is the mirror image: delete the Secrets Manager entry and
the cluster (and everything ArgoCD deployed to it) is torn down on the next
refresh.

A `register-spoke.sh <cluster-name>` wrapping steps 1-3 against `kubectl
--context <spoke>` and `aws secretsmanager put-secret-value` is worth
writing next — not included here since it depends on how you're
provisioning spoke nodes (Terraform output, kOps, eksctl, etc.).
