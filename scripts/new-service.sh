#!/usr/bin/env bash
# Scaffolds a service: one subscription per cluster in this repository, and a new
# config repository (a sibling directory, ready to push) holding the service's
# manifests, copied from the templates repository's web-service scaffold.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

usage() {
  cat >&2 <<EOF
Usage: scripts/new-service.sh <name> --image <repo> --tag <tag> [options]
  --image <repo>      image repository without a tag, e.g. ghcr.io/you/orders
  --tag <tag>         first image tag to deploy, e.g. 1.0.0
  --port <n>          container port (default 8000)
  --health <path>     liveness and readiness path (default /healthz)
  --role <text>       one line for the menus (default: a service)
  --team <name>       owning team (default: team-<name>)
  --envs <a,b>        environments to create (default: dev,prod)
  --clusters <a,b>    clusters to subscribe to (default: all in the registry)
  --depends-on <s>    a service this one calls (repeatable)
EOF
  exit 1
}

NAME="${1:-}"; [[ -n "$NAME" ]] || usage; shift
PORT=8000; HEALTH=/healthz; IMAGE=""; TAG=""; ROLE="a service"; TEAM=""; ENVS="dev,prod"; CLUSTERS=""; DEPS=()
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --image) IMAGE="$2" ;;
    --tag) TAG="$2" ;;
    --port) PORT="$2" ;;
    --health) HEALTH="$2" ;;
    --role) ROLE="$2" ;;
    --team) TEAM="$2" ;;
    --envs) ENVS="$2" ;;
    --clusters) CLUSTERS="$2" ;;
    --depends-on) DEPS+=("$2") ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$IMAGE" && -n "$TAG" ]] || usage
TEAM="${TEAM:-team-$NAME}"
CLUSTERS="${CLUSTERS:-$(IFS=,; echo "${LFI_CLUSTERS[*]}")}"

[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: name must be lowercase letters, digits and dashes." >&2; exit 1; }
[[ "$NAME" != postgres ]] || { echo "ERROR: postgres is a datastore, not a service." >&2; exit 1; }
[[ " ${LFI_SERVICES[*]-} " != *" $NAME "* ]] || { echo "ERROR: $NAME already has a subscription." >&2; exit 1; }
for c in ${CLUSTERS//,/ }; do
  [[ " ${LFI_CLUSTERS[*]} " == *" $c "* ]] || { echo "ERROR: '$c' is not a cluster in the registry." >&2; exit 1; }
done
# `${DEPS[@]+...}` because bash 3.2 treats an empty array as unset under set -u.
for d in ${DEPS[@]+"${DEPS[@]}"}; do
  [[ " ${LFI_SERVICES[*]-} " == *" $d "* ]] || { echo "ERROR: --depends-on $d has no subscription." >&2; exit 1; }
done

TEMPLATES_DIR="$(dirname "$GITOPS_ROOT")/$PROJECT-service-templates"
SCAFFOLD="$TEMPLATES_DIR/scaffolds/web-service"
[[ -d "$SCAFFOLD" ]] || { echo "ERROR: $SCAFFOLD not found. Clone the templates repository next to this one." >&2; exit 1; }
CFG="$(dirname "$GITOPS_ROOT")/$PROJECT-$NAME-config"
[[ ! -e "$CFG" ]] || { echo "ERROR: $CFG already exists." >&2; exit 1; }

# Pin to the newest tag of the templates repository, so the new service starts on
# a released version and not on whatever main happens to hold.
TEMPLATES_URL="${TEMPLATES_URL:-https://github.com/$OWNER/$PROJECT-service-templates}"
TEMPLATES_REF="${TEMPLATES_REF:-$(git -C "$TEMPLATES_DIR" describe --tags --abbrev=0 2>/dev/null || true)}"
[[ -n "$TEMPLATES_REF" ]] || { echo "ERROR: the templates repository has no tag. Tag a release first." >&2; exit 1; }
comp() { echo "${TEMPLATES_URL}//components/$1?ref=${TEMPLATES_REF}"; }

# --- The config repository ---
mkdir -p "$CFG/base/app" "$CFG/.github"
for f in kustomization.yaml rollout.yaml service.yaml; do
  sed -e "s#__NAME__#$NAME#g" -e "s#__PORT__#$PORT#g" -e "s#__HEALTH__#$HEALTH#g" \
    "$SCAFFOLD/$f" > "$CFG/base/app/$f"
done

for cluster in ${CLUSTERS//,/ }; do
  for env in ${ENVS//,/ }; do
    dir="$CFG/$cluster/$env"
    mkdir -p "$dir/app"
    printf '# This directory is one environment of %s on the %s cluster.\n# ArgoCD finds it by this file.\nenv: %s\n' "$NAME" "$cluster" "$env" > "$dir/env.yaml"
    {
      cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE_PREFIX}-${env}
resources:
  - ../../../base/app
EOF
      # Environments called dev and prod get the platform's usual behaviour.
      # Any other name starts plain; add the components you want.
      case "$env" in
        dev)  printf 'components:\n  - %s\n' "$(comp replicas-1)" ;;
        prod) printf 'components:\n  - %s\n' "$(comp canary-manual-gate)" ;;
      esac
      cat <<EOF
images:
  - name: ${NAME}
    newName: ${IMAGE}
    newTag: ${TAG}
EOF
    } > "$dir/app/kustomization.yaml"
  done
done

cat > "$CFG/.github/CODEOWNERS" <<EOF
# This repository belongs to the team that runs $NAME. What it protects is the
# team's decision; the platform only suggests. Prod changes need a review:
/*/prod/    @$OWNER
EOF
cat > "$CFG/README.md" <<EOF
# $PROJECT-$NAME-config

Kubernetes manifests for $NAME, one directory per cluster and environment:

    <cluster>/<environment>/env.yaml       marks an environment (ArgoCD finds it)
    <cluster>/<environment>/app/           what runs
    base/app/                              the service's own manifests

The platform reads this repository because platform/subscriptions/ in
$PROJECT-infrastructure-gitops names it. CI writes \`images[0].newTag\` in
<cluster>/dev/app/kustomization.yaml. A release moves that tag to prod.
EOF
git -C "$CFG" init -q -b main
git -C "$CFG" add -A
git -C "$CFG" commit -q -m "scaffold $NAME from web-service $TEMPLATES_REF"

# --- The subscriptions ---
for cluster in ${CLUSTERS//,/ }; do
  mkdir -p "$SUBSCRIPTIONS/$cluster"
  f="$SUBSCRIPTIONS/$cluster/$NAME.yaml"
  {
    echo "# $NAME on the $cluster cluster. The ApplicationSets read this file."
    echo "name: $NAME"
    echo "team: $TEAM"
    echo "role: $ROLE"
    if [[ ${#DEPS[@]} -gt 0 ]]; then
      echo "dependsOn: [$(IFS=,; echo "${DEPS[*]}" | sed 's/,/, /g')]"
    fi
    echo "# The repo ArgoCD reads this service's manifests from. The team owns it."
    echo "configRepo: https://github.com/$OWNER/$PROJECT-$NAME-config.git"
    echo "# Which environments a release promotes between."
    echo "promotion:"
    echo "  from: dev"
    echo "  to: prod"
  } > "$f"
done

# --- Its ApplicationSets ---
# After the cutover (guide 4, Task 20.3.6) every subscription needs its own
# generated sets, and the contract check fails without them. Before it, the sets
# are not in the repo yet, and writing them would put them live early.
if ls -d argocd/apps-*/appsets/services >/dev/null 2>&1; then
  "$SCRIPT_DIR/gen-appsets.sh"
  echo "Wrote its ApplicationSets under argocd/apps-<cluster>/appsets/."
fi

echo "Created $CFG and subscriptions on: ${CLUSTERS//,/ }."
echo
echo "Next:"
echo "  1. Create and push the config repository:"
echo "       cd $CFG && gh repo create $OWNER/$PROJECT-$NAME-config --public --source . --push"
echo "  2. In the service's own repository, point its CI at the config repository (guide 4, Task 20.3.7 shows the edit):"
echo "       the promote job checks out $OWNER/$PROJECT-$NAME-config and edits"
for cluster in ${CLUSTERS//,/ }; do
  echo "         $cluster/dev/app/kustomization.yaml"
done
echo "  3. Here: scripts/check-contract.sh, commit the subscriptions and the sets (git add platform argocd), merge."
echo "     ArgoCD creates ${NAME}-<env> on its own."
