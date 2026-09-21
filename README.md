# lfi-infrastructure-gitops

ArgoCD's source of truth for a local GitOps Kubernetes platform. Terraform, Kustomize,
ArgoCD, Argo Rollouts.

**Companion to a build guide.** This is the reference version of what you build across
[local-full-infrastructure](https://github.com/mhonnczedz1/local-full-infrastructure).
Read the guide for why it is shaped this way; clone this only to compare against your own.

## The two rules

**Nobody runs `kubectl apply` against the cluster.** ArgoCD reconciles continuously, so
a manual change is reverted within a reconciliation window, silently and with no error.
Deploying means committing.

**`kubernetes/overlays/prod/` is gated.** CODEOWNERS requires review on that path and on
`terraform/`, so prod changes only through a reviewed release pull request. Dev is
continuous and deliberately unowned.

## Layout

```
terraform/
  01-cluster/     creates the k3d cluster. null and local providers only.
  02-platform/    namespaces, secrets, ArgoCD, Argo Rollouts, the root Application.
kubernetes/
  base/           one definition of each workload. No namespace, no image tag.
  overlays/       dev and prod. Only the differences: namespace, tag, replicas, host.
argocd/apps/      six child Applications, three per environment.
scripts/          release.sh, which opens the weekly prod promotion PR.
releases/         denied-builds.yaml, the veto list.
```

Terraform is split into two root modules because the `kubernetes` and `helm` providers
need a reachable cluster at plan time, and the cluster does not exist during the first
apply. Collapse them into one and the first run can never succeed.

## Common commands

```
gmake up          full bring-up, in the required order
gmake pause       stop the node containers, keeping all state
gmake destroy     tear down everything including the cluster
gmake urls        print the ingress URLs for both environments
gmake release     open the weekly prod release PR
gmake canary-status  SVC=service-1   watch an in-flight prod rollout
gmake canary-promote SVC=service-1   complete a paused rollout
gmake canary-abort   SVC=service-1   scale the canary to zero
```

`gmake help` lists every target. Note `gmake`, not `make`: macOS ships GNU Make 3.81,
which silently ignores two directives this Makefile depends on.

## Secrets

`.env` is gitignored and holds the per-environment Postgres passwords. Terraform reads
it locally and creates the Kubernetes Secrets directly, so Git only ever contains a
`secretKeyRef` naming a Secret. Copy `.env.example` to get started.

The consequence worth knowing: the cluster is reproducible from Git plus `.env`, not
from Git alone. Sealed Secrets is the upgrade path.

## Related

The two application repos that feed this one, each writing a single image tag into the
dev overlay:
[lfi-service-1-app](https://github.com/mhonnczedz1/lfi-service-1-app) (gateway),
[lfi-service-2-app](https://github.com/mhonnczedz1/lfi-service-2-app) (worker).
