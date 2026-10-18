#!/usr/bin/env bash
# Writes the ApplicationSets and the teams AppProject from platform/registry.yaml.
#
# Usage: scripts/gen-appsets.sh [output dir]
#   With no argument it writes into the repo, where the root Application picks
#   the files up. Two ApplicationSets per subscription, and one project:
#     argocd/apps-<cluster>/appsets/services/<service>.yaml
#     argocd/apps-<cluster>/appsets/data/<service>.yaml
#     argocd/apps-<cluster>/projects/teams.yaml
#   With a directory it writes services-<cluster>-<service>.yaml,
#   data-<cluster>-<service>.yaml and teams-<cluster>.yaml there instead, and
#   touches nothing in the repo. The cutover uses that to stage the files
#   before they go live.
#
# Why one set per subscription and not one set for all of them: an
# ApplicationSet whose generator cannot read a repository applies nothing at
# all until it can. With one set for every service, a single config repository
# that is deleted, renamed or made private would freeze every service's holds,
# overrides and changes. With one set each, it freezes only its own service.
#
# Each run first removes the sets it wrote last time, so a service whose
# subscription was deleted loses its generated files too.
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

# out <kind> <cluster> [service]: where a generated file goes.
out() {
  if [[ -n "$STAGE" ]]; then
    echo "$STAGE/$1-$2${3:+-$3}.yaml"
  elif [[ "$1" == teams ]]; then
    mkdir -p "argocd/apps-$2/projects"; echo "argocd/apps-$2/projects/teams.yaml"
  else
    mkdir -p "argocd/apps-$2/appsets/$1"; echo "argocd/apps-$2/appsets/$1/$3.yaml"
  fi
}

# Remove what the last run wrote. Only this script's own files: the add-ons
# set and anything else under argocd/ are left alone.
if [[ -n "$STAGE" ]]; then
  mkdir -p "$STAGE"
  rm -f "$STAGE"/services-*.yaml "$STAGE"/data-*.yaml "$STAGE"/teams-*.yaml
else
  for c in $(yq '.clusters[].name' "$REGISTRY"); do
    rm -f "argocd/apps-$c/appsets/services/"*.yaml "argocd/apps-$c/appsets/data/"*.yaml
  done
fi

# Both of a service's ApplicationSets start from the same first generator: its
# one subscription file. Written once here, indented to fit under
# `matrix.generators`. The merge generator lays a platform override on top of
# the subscription; if your ArgoCD does not accept the nesting, set
# `useMerge: false` in the registry and the plain subscription generator is
# used instead (Appendix I).
USE_MERGE="$(yq '.useMerge' "$REGISTRY")"
services_generator() { # <cluster> <subscription file name>
  if [[ "$USE_MERGE" == "false" ]]; then
    cat <<EOF
          # 1. This service's subscription on this cluster.
          - git:
              repoURL: $URL
              revision: HEAD
              files:
                - path: platform/subscriptions/$1/$2
EOF
    return 0
  fi
  cat <<EOF
          # 1. This service's subscription on this cluster. The merge generator
          #    takes the subscription as it is and lays the platform's optional
          #    override for the same name on top. It reads every override on the
          #    cluster, which is harmless: only the one whose name matches is
          #    used, and the overrides live in this repository, which every set
          #    depends on anyway.
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
                      - path: platform/subscriptions/$1/$2
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

  for sub in "$SUBSCRIPTIONS/$c"/*.yaml; do
    [[ -f "$sub" ]] || continue
    svc="$(yq '.name' "$sub")"; file="$(basename "$sub")"

    cat > "$(out services "$c" "$svc")" <<EOF
# One Application per environment of $svc on the $c cluster.
#
# Which service: platform/subscriptions/$c/$file in this repository.
# Which environments: every <env>/env.yaml under $c/ in the service's own
# config repository. The team adds an environment by adding a directory; no
# change here is needed, though its namespace must exist (Terraform creates
# <prefix>-<env> for each name in its environments variable).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services-$c-$svc
  namespace: argocd
  labels:
    platform/kind: services
    platform/service: $svc
spec:
  # Go templates, with an error on any missing key instead of a silent blank.
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
$(services_generator "$c" "$file")
          # 2. The environments in the service's config repository. The second
          #    generator may use the first one's values: the repository to read
          #    is the subscription's configRepo.
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

    cat > "$(out data "$c" "$svc")" <<EOF
# Datastores of $svc on the $c cluster. Same discovery as its services set, but
# with every protection the hand-written postgres Applications had: no prune, no
# cascading delete, and the Application survives the directory being removed.
# A service with no datastore gets this set too; it generates nothing.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: data-$c-$svc
  namespace: argocd
  labels:
    platform/kind: data
    platform/service: $svc
  annotations:
    # root prunes whatever is removed from argocd/, and pruning this set would
    # delete the database's Application with it. This keeps the set until a
    # person deletes it, so unsubscribing a service never takes its database's
    # Application along. root shows OutOfSync until then, which is the reminder.
    argocd.argoproj.io/sync-options: Prune=false
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  # If a postgres directory or the subscription disappears from Git, leave the
  # Application and everything it deployed alone. Losing a database to a bad
  # merge is not a mistake Git history can undo.
  syncPolicy:
    preserveResourcesOnDeletion: true
    applicationsSync: create-update
  generators:
    - matrix:
        generators:
$(services_generator "$c" "$file")
          # 2. Datastore directories in the service's config repository.
          - git:
              repoURL: '{{ .configRepo }}'
              revision: '{{ get . "targetRevision" | default "HEAD" }}'
              directories:
                # To add another kind of datastore, add a line here. Each one
                # needs this ApplicationSet's policy. Two services must not both
                # ship a datastore with the same directory name in one
                # environment: the Application names would collide. One owner
                # per database (guide 4, Task 20.1.2).
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
  done

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
