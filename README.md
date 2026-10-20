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

**This repository holds no service manifests.** A service is a team's entry in
`platform/subscribers.yaml`, taking one of the profiles in `<project>-service-templates`
on the clusters it lists, and pointing at a directory in a config repository the team owns. The generated ApplicationSets read that
directory. Prod, and the list of builds that must never reach it, are protected by the
team's own repository. CODEOWNERS here covers what the platform owns: `platform/`,
`argocd/`, `addons/`, `scripts/` and `terraform/`.

## Layout

~~~
platform/
  registry.yaml          project identity, clusters, and profilesRef: the tag of the
                         templates repository whose profiles/ the generator reads
  subscribers.yaml       every subscription: its team, profile, clusters and where its
                         manifests are
terraform/
  local/, eks/           01-cluster and 02-platform for each cluster
argocd/
  apps-<cluster>/        what root watches: one generated ApplicationSet per
                         subscription, the add-ons set, and the teams project
                         (scripts/gen-appsets.sh writes the generated ones)
addons/<cluster>/        third-party software, one directory per add-on
scripts/                 the commands behind gmake, the registry readers, the contract
                         check, the generator, the scaffolder and the stamp script
~~~

Service manifests live in the teams' `*-config` repositories. The profiles, and the
components and scaffolds that go with them, live in `<project>-service-templates`.

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

## Creating a project from this template

A project is this repository, a templates repository and the teams' config
repositories. All of them are GitHub template repositories, so a new project starts with
no history and none of the old project's tags or secrets.

1. Create the repositories from the templates. `OLD` is the project you are copying
   (owner and project name), `NEW` is the new one:
   ~~~
   OLD_OWNER=<owner>; OLD=lfi; NEW_OWNER=<owner>; NEW=<short>
   gh repo create $NEW_OWNER/$NEW-infrastructure-gitops --template $OLD_OWNER/$OLD-infrastructure-gitops --public --clone
   gh repo create $NEW_OWNER/$NEW-service-templates --template $OLD_OWNER/$OLD-service-templates --public --clone
   for s in service-1 service-2; do
     gh repo create $NEW_OWNER/$NEW-$s-config --template $OLD_OWNER/$OLD-$s-config --public --clone
   done
   ~~~
2. Give the new templates repository its first tag, because a template copy carries
   files and not tags, and every config repository and the registry's `profilesRef` pin one:
   ~~~
   cd $NEW-service-templates && git tag -a v1.0.0 -m "First release" && git push origin v1.0.0
   ~~~
3. Point the copied config repositories at the new templates repository:
   ~~~
   for s in service-1 service-2; do
     cd $NEW-$s-config
     grep -rl "github.com/$OLD_OWNER/$OLD-service-templates" . --include=kustomization.yaml \
       | xargs sed -i '' "s#github.com/$OLD_OWNER/$OLD-service-templates#github.com/$NEW_OWNER/$NEW-service-templates#g"
     git commit -am "point at the new templates repository" && git push
     cd ..
   done
   ~~~
   If you will give the new project a different namespace prefix (`--ns-prefix`), change it
   in the config repositories too, because each environment kustomization names its namespace:
   ~~~
   grep -rl 'namespace: platform-' $NEW-service-1-config $NEW-service-2-config --include=kustomization.yaml \
     | xargs sed -i '' "s#namespace: platform-#namespace: <prefix>-#g"
   ~~~
4. Create an S3 bucket for the new project's Terraform state, then, in the new GitOps repo:
   ~~~
   scripts/stamp.sh --owner <owner> --repo <new-repo> --project <short> --bucket <bucket>
   scripts/stamp.sh --owner <owner> --repo <new-repo> --project <short> --bucket <bucket> --apply
   scripts/check-contract.sh
   ~~~
5. Copy `.env.example` to `.env` and fill it in. Set `GITOPS_REPO_URL` to the new repository.
   Set `ARGOCD_REPO_PAT` to a fine-grained token with Contents: Read on all of the new
   owner's repositories, so a config repository made private stays readable (guide 4,
   Task 20.2.5). Note its expiry date: an expired token stops ArgoCD reading anything.
   If the new owner is a GitHub organization, also clear "Allow members to change
   repository visibilities" under the organization's Member privileges.
6. Bring up a cluster with `gmake up`. The two example services deploy from their
   public images, so you have a working platform at once.
7. Replace them: `gmake add-service` for each of yours, then delete the examples'
   entries from `platform/subscribers.yaml` (`team-1` and `team-2`), regenerate
   (`scripts/gen-appsets.sh`), and delete their config repositories.

Each service repository's CI names its own config repository and the files to update
(see the `promote` job). Copy an existing `ci.yaml` and change `IMAGE_NAME`,
`SERVICE`, the config repository name and the path. `gmake add-service` prints the lines.
