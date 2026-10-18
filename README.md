# lfi-infrastructure-gitops

ArgoCD's source of truth for a local GitOps Kubernetes platform. Terraform, Kustomize,
ArgoCD, Argo Rollouts.

**Companion to a build guide.** This is the reference version of what you build across
[local-full-infrastructure](https://github.com/mhonnczedz1/local-full-infrastructure).
Read the guide for why it is shaped this way; clone this only to compare against your own.

## The rules

**Nobody runs `kubectl apply` against the cluster.** ArgoCD reconciles continuously, so
a manual change is reverted within a reconciliation window, silently and with no error.
Deploying means committing.

**This repository holds no service manifests.** A service is a subscription under
`platform/subscriptions/` that points at a config repository its team owns, and the
ApplicationSets read that repository. Prod is protected by the team's own repository.
CODEOWNERS here covers what the platform owns: `platform/`, `argocd/`, `addons/`,
`releases/`, `scripts/` and `terraform/`.

## Layout

~~~
platform/
  registry.yaml          project identity and clusters
  subscriptions/         one file per service per cluster: where its config repo is
  overrides/             optional platform adjustments to a subscription
terraform/
  local/, eks/           01-cluster and 02-platform for each cluster
argocd/
  apps-<cluster>/        what root watches: generated ApplicationSets and the teams
                         project (scripts/gen-appsets.sh writes them)
addons/<cluster>/        third-party software, one directory per add-on
scripts/                 the commands behind gmake, the registry readers, the contract
                         check, the generator, the scaffolder and the stamp script
releases/                denied-builds.yaml, the veto list.
~~~

Service manifests live in each service's own `<project>-<service>-config` repository, and
the components they build on live in `<project>-service-templates`.

Terraform is split into two root modules because the `kubernetes` and `helm` providers
need a reachable cluster at plan time, and the cluster does not exist during the first
apply. Collapse them into one and the first run can never succeed.

## Common commands

Every command asks for what it needs: the cluster (`local` for k3d, `eks` for AWS, or
`both` where that is safe), the service, the environment. Answer up front to skip a
question. After an interactive run, the command prints its own skip-the-questions form.

```
gmake up        bring a cluster up            gmake up CLUSTER=eks
gmake down      remove the platform, keep the cluster
gmake destroy   remove everything, including data (you type the word)
gmake pause     stop the local cluster        gmake resume starts it again
gmake status    which build runs where, in Git and in the cluster, plus the addresses
gmake release   open a PR promoting dev to prod    gmake release CLUSTER=eks SVC=service-1
gmake rollback  open a PR going back to an earlier prod build
gmake canary    watch, promote or abort a prod canary
```

Variables: `CLUSTER`, `SVC`, `ENVIRONMENT`, `ACTION`, `TO`. `YES=1` skips confirmations.
With no terminal, a missing answer is an error with examples, never a prompt.
Clusters may drift apart: releasing to one leaves the other where it was.

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
