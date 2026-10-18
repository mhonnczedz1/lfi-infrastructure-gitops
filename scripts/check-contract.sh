#!/usr/bin/env bash
# Fails loudly when the repo stops matching platform/registry.yaml and the
# subscriptions. Read-only. Run it after any structural change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

# --online also checks that every config repository named by a subscription can
# be reached. One unreachable repository stops the ApplicationSets from
# generating anything at all until it is fixed, so this is worth asking before a
# subscription ships.
ONLINE=0
[[ "${1:-}" == "--online" ]] && ONLINE=1

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# Cluster identity agrees with the files that hard-code it.
for cluster in "${LFI_CLUSTERS[@]}"; do
  [[ -d "argocd/apps-$cluster" ]] || fail "missing argocd/apps-$cluster"
  [[ -d "terraform/$cluster" ]] || fail "missing terraform/$cluster"
done
k3d_name="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"
cfg_name="$(yq '.metadata.name' terraform/local/01-cluster/k3d-config.yaml)"
[[ "$k3d_name" == "$cfg_name" ]] || fail "registry says the k3d cluster is '$k3d_name' but k3d-config.yaml says '$cfg_name'"

# Every subscription is well formed, sits in the directory of a known cluster,
# and points at the config repo this project's naming convention allows. The
# AppProject trusts repos by that name pattern, so a subscription outside it
# would be created and then refused.
for f in $(subscription_files); do
  cluster="$(basename "$(dirname "$f")")"
  name="$(yq '.name' "$f")"
  url="$(yq '.configRepo' "$f")"
  [[ " ${LFI_CLUSTERS[*]} " == *" $cluster "* ]] || fail "$f is under '$cluster', which is not a cluster in the registry"
  [[ "$name" == "$(basename "$f" .yaml)" ]] || fail "$f names service '$name': the file name must match"
  for key in name team role configRepo; do
    v="$(K="$key" yq '.[strenv(K)]' "$f")"
    [[ -n "$v" && "$v" != null ]] || fail "$f has no '$key'"
  done
  want="https://github.com/$OWNER/$PROJECT-$name-config.git"
  [[ "$url" == "$want" ]] || fail "$f: configRepo is $url, expected $want"
  for dep in $(yq '.dependsOn[]?' "$f"); do
    [[ " ${LFI_SERVICES[*]} " == *" $dep "* ]] || fail "$f: dependsOn $dep, which has no subscription"
  done
done

# A service subscribed on one cluster must say the same thing about its config
# repo on every cluster, or the clusters would read different repos by accident.
for svc in "${LFI_SERVICES[@]}"; do
  urls="$(for f in $(subscription_files); do
    if [[ "$(yq '.name' "$f")" == "$svc" ]]; then yq '.configRepo' "$f"; fi
  done | sort -u | wc -l | tr -d ' ')"
  [[ "$urls" == 1 ]] || fail "$svc is subscribed with $urls different configRepo values"
done

# Manifests under argocd/ repeat the repo URL because ArgoCD cannot read the
# registry. Any Git URL (one ending in .git) in a repoURL field must match it.
# Helm chart repositories do not end in .git, so they are ignored.
want_url="https://github.com/$OWNER/$(yq '.repo' "$REGISTRY").git"
for f in $(find argocd -name '*.yaml' 2>/dev/null); do
  while IFS= read -r url; do
    [[ "$url" == "$want_url" ]] || fail "$f names repoURL $url, registry says $want_url"
  done < <(yq '.. | select(has("repoURL")) | .repoURL' "$f" 2>/dev/null | grep '\.git$' | grep -v '{{' || true)
done

if [[ "$ONLINE" -eq 1 ]]; then
  for svc in "${LFI_SERVICES[@]}"; do
    url="$(service_config_url "$svc")"
    # No credential prompt: a repository that does not exist asks for a login.
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; then
      fail "$svc's config repository $url cannot be reached"
    fi
  done
fi

# The ApplicationSets and the teams project are generated from the registry.
# Regenerate into a temporary directory and compare, so a hand edit, or a
# registry change that forgot to regenerate, is caught. Only once the generator
# exists (Phase 20.2) and only for files that have been put in place.
if [[ -x "$SCRIPT_DIR/gen-appsets.sh" ]]; then
  gen="$(mktemp -d)"; trap 'rm -rf "$gen"' EXIT
  "$SCRIPT_DIR/gen-appsets.sh" "$gen" >/dev/null
  for cluster in "${LFI_CLUSTERS[@]}"; do
    for kind in services data; do
      f="argocd/apps-$cluster/appsets/$kind.yaml"
      if [[ -f "$f" ]] && ! diff -q "$f" "$gen/$kind-$cluster.yaml" >/dev/null; then
        fail "$f differs from scripts/gen-appsets.sh. Regenerate it: scripts/gen-appsets.sh"
      fi
    done
    f="argocd/apps-$cluster/projects/teams.yaml"
    if [[ -f "$f" ]] && ! diff -q "$f" "$gen/teams-$cluster.yaml" >/dev/null; then
      fail "$f differs from scripts/gen-appsets.sh. Regenerate it: scripts/gen-appsets.sh"
    fi
  done
fi

if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS problem(s). The repo and its registry or subscriptions disagree." >&2
  exit 1
fi
echo "OK: ${#LFI_SERVICES[@]} service(s) x ${#LFI_CLUSTERS[@]} cluster(s) match the registry."
