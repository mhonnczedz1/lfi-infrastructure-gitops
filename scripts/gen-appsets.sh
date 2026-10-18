#!/usr/bin/env bash
# Writes the ApplicationSets and the teams AppProject from platform/registry.yaml.
#
# Usage: scripts/gen-appsets.sh [output dir]
#   With no argument it writes into the repo, where the root Application picks
#   the files up:
#     argocd/apps-<cluster>/appsets/services.yaml
#     argocd/apps-<cluster>/appsets/data.yaml
#     argocd/apps-<cluster>/projects/teams.yaml
#   With a directory it writes services-<cluster>.yaml, data-<cluster>.yaml and
#   teams-<cluster>.yaml there instead, and touches nothing in the repo. The
#   cutover uses that to stage the files before they go live.
#
# ArgoCD cannot read the registry, so the few values the ApplicationSets need
# (the repo URL, the owner, the namespace prefix) are written into them here.
# scripts/check-contract.sh regenerates into a temporary directory and fails if
# a committed file differs, so a hand edit or a stale copy cannot go unnoticed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

STAGE="${1:-}"
URL="https://github.com/$OWNER/$(yq '.repo' "$REGISTRY").git"

# out <kind> <cluster>: where a generated file goes.
out() {
  if [[ -n "$STAGE" ]]; then
    mkdir -p "$STAGE"; echo "$STAGE/$1-$2.yaml"
  else
    local dir="argocd/apps-$2/appsets"; [[ "$1" == teams ]] && dir="argocd/apps-$2/projects"
    mkdir -p "$dir"; echo "$dir/$1.yaml"
  fi
}

# Both ApplicationSets start from the same first generator: the services this
# cluster subscribes to. Written once here, indented to fit under
# `matrix.generators`. The merge generator lays a platform override on top of
# each subscription; if your ArgoCD does not accept the nesting, set
# `useMerge: false` in the registry and the plain subscription generator is
# used instead (Appendix I).
USE_MERGE="$(yq '.useMerge' "$REGISTRY")"
services_generator() { # <cluster>
  if [[ "$USE_MERGE" == "false" ]]; then
    cat <<EOF
          # 1. The services this cluster subscribes to.
          - git:
              repoURL: $URL
              revision: HEAD
              files:
                - path: platform/subscriptions/$1/*.yaml
EOF
    return 0
  fi
  cat <<EOF
          # 1. The services this cluster subscribes to. The merge generator
          #    takes each subscription as it is and lays the platform's optional
          #    override for the same name on top.
          - merge:
              mergeKeys: [name]
              generators:
                - git:
                    repoURL: $URL
                    revision: HEAD
                    # Keeps this generator's path values under .subscription, so
                    # they cannot collide with the .path of the second generator.
                    pathParamPrefix: subscription
                    files:
                      - path: platform/subscriptions/$1/*.yaml
                - git:
                    repoURL: $URL
                    revision: HEAD
                    pathParamPrefix: override
                    files:
                      - path: platform/overrides/$1/*.yaml
EOF
}

for c in $(yq '.clusters[].name' "$REGISTRY"); do
  sfx=""; [[ "$c" == eks ]] && sfx="-eks"

  cat > "$(out services "$c")" <<EOF
# One Application per service per environment on the $c cluster.
#
# Which services: platform/subscriptions/$c/*.yaml in this repository.
# Which environments: every <env>/env.yaml under $c/ in the service's own
# config repository. The team adds an environment by adding a directory; no
# change here is needed, though its namespace must exist (Terraform creates
# <prefix>-<env> for each name in its environments variable).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services-$c
  namespace: argocd
spec:
  # Go templates, with an error on any missing key instead of a silent blank.
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
$(services_generator "$c")
          # 2. For each of those, the environments in its config repository.
          #    The second generator may use the first one's values: the
          #    repository to read is the subscription's configRepo.
          - git:
              repoURL: '{{ .configRepo }}'
              revision: '{{ get . "targetRevision" | default "HEAD" }}'
              files:
                - path: '$c/*/env.yaml'
  template:
    metadata:
      # Same names as the hand-written Applications this replaces, which is what
      # lets the new Application adopt what is already running.
      name: '{{ .name }}-{{ .env }}$sfx'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      # Not "default": the teams project limits which repositories may be read,
      # which namespaces may be written, and forbids cluster-scoped resources.
      project: teams
      source:
        repoURL: '{{ .configRepo }}'
        targetRevision: '{{ get . "targetRevision" | default "HEAD" }}'
        # path.path is the directory env.yaml sits in, for example local/dev.
        path: '{{ .path.path }}/app'
      destination:
        server: https://kubernetes.default.svc
        # A team may name its own namespace in env.yaml. The project still
        # refuses any that does not start with the platform's prefix.
        namespace: '{{ get . "namespace" | default (printf "%s-%s" "$NAMESPACE_PREFIX" .env) }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 2m
EOF

  cat > "$(out data "$c")" <<EOF
# Datastores on the $c cluster. Same discovery as the services, but with every
# protection the hand-written postgres Applications had: no prune, no cascading
# delete, and the Application survives the directory being removed.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: data-$c
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  # If a postgres directory or a whole subscription disappears from Git, leave
  # the Application and everything it deployed alone. Losing a database to a bad
  # merge is not a mistake Git history can undo.
  syncPolicy:
    preserveResourcesOnDeletion: true
    applicationsSync: create-update
  generators:
    - matrix:
        generators:
$(services_generator "$c")
          # 2. Datastore directories in that service's config repository.
          - git:
              repoURL: '{{ .configRepo }}'
              revision: '{{ get . "targetRevision" | default "HEAD" }}'
              directories:
                # To add another kind of datastore, add a line here. Each one
                # needs this ApplicationSet's policy. Two services must not both
                # ship a datastore with the same directory name in one
                # environment: the Application names would collide.
                - path: '$c/*/postgres'
  template:
    metadata:
      # path.segments is [$c, <environment>, postgres].
      name: '{{ .path.basename }}-{{ index .path.segments 1 }}$sfx'
      # No finalizer: deleting this Application must not delete the database.
    spec:
      project: teams
      source:
        repoURL: '{{ .configRepo }}'
        targetRevision: '{{ get . "targetRevision" | default "HEAD" }}'
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '$NAMESPACE_PREFIX-{{ index .path.segments 1 }}'
      syncPolicy:
        automated:
          # false: a file removed from Git must not delete the StatefulSet.
          prune: false
          selfHeal: true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 2m
      ignoreDifferences:
        # volumeClaimTemplates are immutable after creation and the API server
        # returns them with defaulted fields, which ArgoCD reads as permanent
        # drift. Without this the app sits OutOfSync forever.
        - group: apps
          kind: StatefulSet
          jsonPointers:
            - /spec/volumeClaimTemplates
EOF

  cat > "$(out teams "$c")" <<EOF
# What team-owned repositories are allowed to do on the $c cluster. Every
# Application the ApplicationSets create belongs to this project, so this file
# is the boundary between "the platform trusts the team's repo to say what runs"
# and "the team's repo can run anything it likes".
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: teams
  namespace: argocd
spec:
  description: Services whose manifests live in team-owned config repositories.
  # Only repositories that follow the naming convention. The scaffolder and
  # scripts/check-contract.sh create and check names of this shape.
  sourceRepos:
    - https://github.com/$OWNER/$PROJECT-*-config.git
  # Only the platform's namespaces. A team that sets namespace: kube-system in
  # its env.yaml gets a sync error, not a deployment into kube-system.
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '$NAMESPACE_PREFIX-*'
  # Nothing cluster-wide: no Namespaces, ClusterRoles, CRDs or webhooks.
  clusterResourceWhitelist: []
  # Inside its namespaces a team may not grant itself access or lift its limits.
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: Role
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
EOF
done
