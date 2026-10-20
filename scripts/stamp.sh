#!/usr/bin/env bash
# Re-labels a copy of this repo as a new project: new GitHub owner and repo,
# new cluster names, new namespaces, new state bucket, and the names of the
# config and templates repositories it expects to find. Run it once, in a fresh
# copy made from the GitHub template, before anything is applied.
#
# Dry run by default. Add --apply to change files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"
# reg.sh reads the project's current owner and name into OWNER and PROJECT.
# Keep them under other names; the arguments below use OWNER and PROJECT for the new ones.
OWNER_NOW="$OWNER"; PROJECT_NOW="$PROJECT"

usage() {
  cat >&2 <<EOF
Usage: scripts/stamp.sh --owner <github owner> --repo <repo name> --project <short name> \\
                        --bucket <state bucket> [--ns-prefix <prefix>] [--apply]
  --project    short lowercase name, e.g. mktp. Becomes the cluster names:
               k3d cluster <project>, EKS cluster <project>-eks.
  --ns-prefix  namespace prefix (default: the project), giving <prefix>-<environment>
  --bucket     an S3 bucket you have already created for Terraform state
EOF
  exit 1
}

OWNER=""; REPO=""; PROJECT=""; BUCKET=""; NSP=""; APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift; continue ;;
    --owner|--repo|--project|--bucket|--ns-prefix) [[ $# -ge 2 ]] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --owner) OWNER="$2" ;;
    --repo) REPO="$2" ;;
    --project) PROJECT="$2" ;;
    --bucket) BUCKET="$2" ;;
    --ns-prefix) NSP="$2" ;;
  esac
  shift 2
done
[[ -n "$OWNER" && -n "$REPO" && -n "$PROJECT" && -n "$BUCKET" ]] || usage
NSP="${NSP:-$PROJECT}"
[[ "$PROJECT" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "ERROR: --project must be 2 to 16 lowercase letters and digits." >&2; exit 1; }
[[ "$NSP" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "ERROR: --ns-prefix must be 2 to 16 lowercase letters and digits." >&2; exit 1; }

OLD_OWNER="$OWNER_NOW"; OLD_REPO="$(yq '.repo' "$REGISTRY")"; OLD_PROJECT="$PROJECT_NOW"
OLD_BUCKET="$(yq '.stateBucket' "$REGISTRY")"; OLD_NSP="$(yq '.namespacePrefix' "$REGISTRY")"
OLD_K3D="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"

[[ "$OLD_OWNER/$OLD_REPO" != "$OWNER/$REPO" ]] || { echo "ERROR: the registry already says $OWNER/$REPO. Nothing to stamp." >&2; exit 1; }

# Files that carry each old value. grep -rl lists them, so the dry run shows
# exactly what --apply would touch.
URL_FILES="$(grep -rl "github.com/$OLD_OWNER/$OLD_REPO.git" argocd 2>/dev/null || true)"
BACKEND_FILES="$(grep -rl "$OLD_BUCKET" terraform --include=backend.tf 2>/dev/null || true)"
OWNER_FILES="$(grep -l "@$OLD_OWNER" .github/CODEOWNERS 2>/dev/null || true)"
# Subscriptions name the config repositories, under the owner. A repository
# named after the old project (<project>-...-config) is renamed after the new one.
SUB_FILES="$(grep -rl "github.com/$OLD_OWNER/" platform/subscriptions 2>/dev/null || true)"

echo "Stamping $OLD_OWNER/$OLD_REPO as $OWNER/$REPO (project $PROJECT, namespaces ${NSP}-<environment>)"
echo
echo "Registry:            platform/registry.yaml (owner, repo, bucket, prefixes, cluster names)"
echo "k3d cluster name:    $OLD_K3D -> $PROJECT   (terraform/local/01-cluster/k3d-config.yaml)"
echo "Repo URL in:         $(echo "$URL_FILES" | grep -c . || true) file(s) under argocd/"
echo "State bucket in:     $(echo "$BACKEND_FILES" | grep -c . || true) backend.tf file(s)"
echo "Subscriptions:       $(echo "$SUB_FILES" | grep -c . || true) file(s) naming config repositories"
echo "Generated files:     ApplicationSets and teams project, regenerated from the registry"
echo "Code owner in:       $(echo "$OWNER_FILES" | grep -c . || true) file(s)"

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "Dry run. Nothing changed. Add --apply to make these changes."
  exit 0
fi

for f in $URL_FILES; do
  sed -i '' "s#github.com/$OLD_OWNER/$OLD_REPO.git#github.com/$OWNER/$REPO.git#g" "$f"
done
for f in $BACKEND_FILES; do
  sed -i '' "s#$OLD_BUCKET#$BUCKET#g" "$f"
done
for f in $SUB_FILES; do
  sed -i '' -e "s#github.com/$OLD_OWNER/$OLD_PROJECT-#github.com/$OWNER/$PROJECT-#g" \
            -e "s#github.com/$OLD_OWNER/#github.com/$OWNER/#g" "$f"
done
for f in $OWNER_FILES; do
  sed -i '' "s#@$OLD_OWNER#@$OWNER#g" "$f"
done

P="$PROJECT" yq -i '.metadata.name = strenv(P)' terraform/local/01-cluster/k3d-config.yaml

O="$OWNER" R="$REPO" B="$BUCKET" P="$PROJECT" N="$NSP" yq -i '
  .project = strenv(P) |
  .owner = strenv(O) |
  .repo = strenv(R) |
  .stateBucket = strenv(B) |
  .namespacePrefix = strenv(N) |
  (.clusters[] | select(.kind == "k3d") | .clusterName) = strenv(P) |
  (.clusters[] | select(.kind == "k3d") | .context) = "k3d-" + strenv(P) |
  (.clusters[] | select(.kind == "k3d") | .stateKeyPrefix) = strenv(P) + "-local" |
  (.clusters[] | select(.kind == "eks") | .clusterName) = strenv(P) + "-eks" |
  (.clusters[] | select(.kind == "eks") | .context) = strenv(P) + "-eks" |
  (.clusters[] | select(.kind == "eks") | .stateKeyPrefix) = strenv(P) + "-eks"
' "$REGISTRY"

# The ApplicationSets and the project hold the owner, repo and namespace prefix.
# Regenerate them instead of editing them.
scripts/gen-appsets.sh

echo
echo "Done. Verify:  scripts/check-contract.sh"
echo "Then commit, and create these GitHub repositories under $OWNER:"
echo "  $REPO                          (this repository)"
echo "  $PROJECT-service-templates     (from $OLD_OWNER/$OLD_PROJECT-service-templates)"
# One per repository the subscriptions name, however many services share it.
for repo in $(yq -N '.configRepo' $(ls platform/subscriptions/*/*.yaml) | sort -u); do
  repo="$(basename "$repo" .git)"
  echo "  $repo           (from $OLD_OWNER/${repo/#$PROJECT-/$OLD_PROJECT-})"
done
echo "See 'Creating a project from this template' in README.md for the commands."
