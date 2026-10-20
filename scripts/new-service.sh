#!/usr/bin/env bash
# Scaffolds a service: its entry in platform/subscribers.yaml, and the
# service's manifests in a config repository (a sibling directory), copied from
# the templates repository's scaffold for its profile. The repository can be new
# (created here, ready to push) or one the team already has, in which case the
# service goes into its own directory there (--path).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

usage() {
  cat >&2 <<EOF
Usage: scripts/new-service.sh <name> --team <team> [options]
  The service's identity is <team>-<name>.
  --team <team>        owning team, e.g. team-3 (required)
  --profile <p>        web-service (default) or db-service
  --repo <name>        config repository, ending in -config (default: $PROJECT-<name>-config).
                       If it is already cloned next to this repository, the service
                       is added to it, and --path is required.
  --path <dir>         directory inside the repository (default: the root of a new repository)
  --image <repo>       web-service: image repository without a tag (required)
  --tag <tag>          web-service: first image tag to deploy (required)
  --port <n>           container port (default 8000 for web-service, 5432 for db-service)
  --health <path>      web-service: liveness and readiness path (default /healthz)
  --storage <size>     db-service: volume size (default 1Gi)
  --description <text> one line for the menus (default: a service)
  --envs <a,b>         environments to create, in promotion order (default: dev,prod);
                       CI writes the first, releases move along the rest
  --clusters <a,b>     clusters to subscribe to (default: all in the registry)
  --depends-on <id>    a service this one calls, by identity (repeatable)
EOF
  exit 1
}

NAME="${1:-}"; [[ -n "$NAME" && "$NAME" != --* ]] || usage; shift
TEAM=""; PROFILE=web-service; REPO=""; RPATH=""; IMAGE=""; TAG=""; PORT=""; HEALTH=/healthz
STORAGE=1Gi; DESC="a service"; ENVS="dev,prod"; CLUSTERS=""; DEPS=()
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --team) TEAM="$2" ;;
    --profile) PROFILE="$2" ;;
    --repo) REPO="$2" ;;
    --path) RPATH="$2" ;;
    --image) IMAGE="$2" ;;
    --tag) TAG="$2" ;;
    --port) PORT="$2" ;;
    --health) HEALTH="$2" ;;
    --storage) STORAGE="$2" ;;
    --description) DESC="$2" ;;
    --envs) ENVS="$2" ;;
    --clusters) CLUSTERS="$2" ;;
    --depends-on) DEPS+=("$2") ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$TEAM" ]] || usage
ID="$TEAM-$NAME"
REPO="${REPO:-$PROJECT-$NAME-config}"
CLUSTERS="${CLUSTERS:-$(IFS=,; echo "${LFI_CLUSTERS[*]}")}"
case "$PROFILE" in
  web-service) PORT="${PORT:-8000}"; [[ -n "$IMAGE" && -n "$TAG" ]] || { echo "ERROR: a web-service needs --image and --tag." >&2; exit 1; } ;;
  db-service)  PORT="${PORT:-5432}" ;;
  *) echo "ERROR: --profile must be web-service or db-service." >&2; exit 1 ;;
esac

[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: name must be lowercase letters, digits and dashes." >&2; exit 1; }
[[ "$TEAM" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: team must be lowercase letters, digits and dashes." >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9._-]+-config$ ]] || { echo "ERROR: --repo must end in -config." >&2; exit 1; }
[[ -z "$RPATH" || "$RPATH" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || { echo "ERROR: --path must be a relative directory." >&2; exit 1; }
[[ " ${LFI_SERVICES[*]-} " != *" $ID "* ]] || { echo "ERROR: $ID already has a subscription." >&2; exit 1; }
[[ -z "$PROFILES_ERROR" ]] || { echo "ERROR: $PROFILES_ERROR." >&2; exit 1; }
[[ -f "$(profile_file "$PROFILE")" ]] || { echo "ERROR: profile $PROFILE is not in the templates repository at $PROFILES_REF." >&2; exit 1; }
for c in ${CLUSTERS//,/ }; do
  [[ " ${LFI_CLUSTERS[*]} " == *" $c "* ]] || { echo "ERROR: '$c' is not a cluster in the registry." >&2; exit 1; }
done
# `${DEPS[@]+...}` because bash 3.2 treats an empty array as unset under set -u.
for d in ${DEPS[@]+"${DEPS[@]}"}; do
  [[ " ${LFI_SERVICES[*]-} " == *" $d "* ]] || { echo "ERROR: --depends-on $d has no subscription." >&2; exit 1; }
  for c in ${CLUSTERS//,/ }; do
    service_on_cluster "$d" "$c" || { echo "ERROR: --depends-on $d is not subscribed on $c." >&2; exit 1; }
  done
done

TEMPLATES_DIR="$(dirname "$GITOPS_ROOT")/$PROJECT-service-templates"
SCAFFOLD="$TEMPLATES_DIR/scaffolds/$PROFILE"
[[ -d "$SCAFFOLD" ]] || { echo "ERROR: $SCAFFOLD not found. Clone the templates repository next to this one." >&2; exit 1; }

# A new repository, or a directory in one the team already has.
CFG="$(dirname "$GITOPS_ROOT")/$REPO"
NEW_REPO=1
if [[ -e "$CFG" ]]; then
  NEW_REPO=0
  [[ -d "$CFG/.git" ]] || { echo "ERROR: $CFG exists but is not a Git repository." >&2; exit 1; }
  [[ -n "$RPATH" ]] || { echo "ERROR: $CFG already exists. Give the new service its own directory there with --path." >&2; exit 1; }
  [[ -z "$(git -C "$CFG" status --porcelain)" ]] || { echo "ERROR: $CFG has uncommitted changes." >&2; exit 1; }
fi
DIR="$CFG${RPATH:+/$RPATH}"
# Another service in the same repository must not share or contain this path.
for s in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
  [[ "$(service_config_url "$s")" == "https://github.com/$OWNER/$REPO.git" ]] || continue
  sp="$(service_repo_path "$s")"
  if [[ -z "$sp" || -z "$RPATH" || "$sp" == "$RPATH" || "$RPATH/" == "$sp/"* || "$sp/" == "$RPATH/"* ]]; then
    echo "ERROR: $s already uses $REPO at '${sp:-the root}', which overlaps '${RPATH:-the root}'." >&2; exit 1
  fi
done
[[ ! -e "$DIR" || "$DIR" == "$CFG" && "$NEW_REPO" -eq 1 ]] || { echo "ERROR: $DIR already exists." >&2; exit 1; }
P="${RPATH:+$RPATH/}"

# Pin to the newest tag of the templates repository, so the new service starts on
# a released version and not on whatever main happens to hold.
TEMPLATES_URL="${TEMPLATES_URL:-https://github.com/$OWNER/$PROJECT-service-templates}"
TEMPLATES_REF="${TEMPLATES_REF:-$(git -C "$TEMPLATES_DIR" describe --tags --abbrev=0 2>/dev/null || true)}"
[[ -n "$TEMPLATES_REF" ]] || { echo "ERROR: the templates repository has no tag. Tag a release first." >&2; exit 1; }
comp() { echo "${TEMPLATES_URL}//components/$1?ref=${TEMPLATES_REF}"; }

# --- The service's directory in the config repository ---
mkdir -p "$DIR/base"
for f in "$SCAFFOLD"/*.yaml; do
  sed -e "s#__NAME__#$NAME#g" -e "s#__PORT__#$PORT#g" -e "s#__HEALTH__#$HEALTH#g" -e "s#__STORAGE__#$STORAGE#g" \
    "$f" > "$DIR/base/$(basename "$f")"
done

for cluster in ${CLUSTERS//,/ }; do
  for env in ${ENVS//,/ }; do
    env_dir="$DIR/$cluster/$env"
    mkdir -p "$env_dir"
    printf '# This directory is one environment of %s on the %s cluster.\n# ArgoCD finds it by this file.\nenv: %s\n' "$ID" "$cluster" "$env" > "$env_dir/env.yaml"
    {
      cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE_PREFIX}-${env}
resources:
  - ../../base
EOF
      # The platform's usual behaviour for the usual names. Any other
      # environment starts plain; add the components you want.
      behaviour=""
      if [[ "$PROFILE" == web-service ]]; then
        case "$env" in dev) behaviour=replicas-1 ;; prod) behaviour=canary-manual-gate ;; esac
      elif [[ "$(cluster_field "$cluster" kind)" == eks ]]; then
        behaviour=storage-gp3
      fi
      if [[ -n "$behaviour" ]]; then printf 'components:\n  - %s\n' "$(comp "$behaviour")"; fi
      if [[ "$PROFILE" == web-service ]]; then
        cat <<EOF
images:
  - name: ${NAME}
    newName: ${IMAGE}
    newTag: ${TAG}
EOF
      fi
    } > "$env_dir/kustomization.yaml"
  done
done

if [[ "$PROFILE" == web-service ]]; then
  cat > "$DIR/denied-builds.yaml" <<EOF
# Builds of $ID that must never be promoted to prod. gmake release reads this
# file and leaves a listed build out of the release.
#
# Example:
#   denied:
#     - build: 26W38B3
#       reason: OOMs at real queue depth after ~6h
#       denied_by: $OWNER
denied: []
EOF
fi

mkdir -p "$CFG/.github"
if [[ ! -f "$CFG/.github/CODEOWNERS" ]]; then
  cat > "$CFG/.github/CODEOWNERS" <<EOF
# This repository belongs to the team that runs it. What it protects is the
# team's decision; the platform only suggests. Prod and the deny list need a review:
EOF
fi
echo "/${P}*/prod/    @$OWNER" >> "$CFG/.github/CODEOWNERS"
[[ "$PROFILE" == web-service ]] && echo "/${P}denied-builds.yaml    @$OWNER" >> "$CFG/.github/CODEOWNERS"
if [[ "$NEW_REPO" -eq 1 ]]; then
  cat > "$CFG/README.md" <<EOF
# $REPO

Kubernetes manifests, owned by $TEAM. Each service here is one subscription in
$PROJECT-infrastructure-gitops, at its own path. Inside a service's directory:

    base/                          the service's own manifests
    <cluster>/<environment>/       one environment: env.yaml (ArgoCD finds it by
                                   this file) and kustomization.yaml
    denied-builds.yaml             builds that must never reach prod (a released
                                   service only)

CI writes \`images[0].newTag\` in <cluster>/dev/kustomization.yaml. A release
moves that tag to prod. An environment's env.yaml may set \`overrides:\`, limited
to the keys the service's profile allows.
EOF
  git -C "$CFG" init -q -b main
fi
git -C "$CFG" add -A
git -C "$CFG" commit -q -m "scaffold $ID from $PROFILE $TEMPLATES_REF"

# --- The subscription: one entry in platform/subscribers.yaml ---
# Written as a small file, then added to the list, which stays sorted by
# identity so that two teams' additions rarely touch the same lines.
entry="$(mktemp)"
{
  echo "name: $NAME"
  echo "team: $TEAM"
  echo "profile: $PROFILE"
  echo "configRepo: https://github.com/$OWNER/$REPO.git"
  [[ -z "$RPATH" ]] || echo "repoPath: $RPATH"
  echo "clusters: [$(echo "$CLUSTERS" | sed 's/,/, /g')]"
  if [[ ${#DEPS[@]} -gt 0 ]]; then
    echo "dependsOn: [$(IFS=,; echo "${DEPS[*]}" | sed 's/,/, /g')]"
  fi
  echo "description: $DESC"
  if [[ "$PROFILE" == web-service ]]; then
    echo "promotion: [$(echo "$ENVS" | sed 's/,/, /g')]"
  fi
} > "$entry"
E="$entry" yq -i '.subscribers += [load(strenv(E))] | .subscribers |= sort_by(.team + "-" + .name)' "$SUBSCRIBERS"
rm -f "$entry"

# --- Its ApplicationSet ---
# After the cutover (guide 4, Task 20.3.6) every subscription needs its own
# generated set, and the contract check fails without it. Before it, the sets
# are not in the repo yet, and writing them would put them live early.
if ls -d argocd/apps-*/appsets/subscriptions >/dev/null 2>&1; then
  "$SCRIPT_DIR/gen-appsets.sh"
  echo "Wrote its ApplicationSet under argocd/apps-<cluster>/appsets/subscriptions/."
fi

echo "Created $ID ($PROFILE) in $DIR and subscribed it on: ${CLUSTERS//,/ }."
echo
echo "Next:"
if [[ "$NEW_REPO" -eq 1 ]]; then
  echo "  1. Create and push the config repository:"
  echo "       cd $CFG && gh repo create $OWNER/$REPO --public --source . --push"
else
  echo "  1. Push the new directory in $REPO (a commit on its current branch):"
  echo "       git -C $CFG push"
fi
if [[ "$PROFILE" == web-service ]]; then
  echo "  2. In the service's own repository, point its CI at the config repository (guide 4, Task 20.3.7 shows the edit):"
  echo "       the promote job checks out $OWNER/$REPO and edits"
  for cluster in ${CLUSTERS//,/ }; do
    echo "         ${P}$cluster/${ENVS%%,*}/kustomization.yaml"
  done
else
  echo "  2. Nothing for CI: a database has no image tag to move."
fi
echo "  3. Here: scripts/check-contract.sh --online, commit the subscription and the set (git add platform argocd), merge."
echo "     ArgoCD creates <env>-$ID on its own."
