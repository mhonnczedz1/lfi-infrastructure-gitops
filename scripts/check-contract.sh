#!/usr/bin/env bash
# Fails loudly when the repo stops matching platform/registry.yaml, the profiles
# and the subscriptions. Read-only. Run it after any structural change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

# --online also reads every config repository a subscription names, anonymously:
# that it can be reached, and what the team has put in it (override keys, a
# database under the wrong profile, a missing deny list). An unreachable
# repository freezes its own service's ApplicationSet until it is fixed, so this
# is worth asking before a subscription ships. A private repository fails here
# too, on purpose: config repositories are public by convention, and ArgoCD's
# credential (Task 20.2.5) is a safety net for a mistake, not permission to make
# one.
ONLINE=0
[[ "${1:-}" == "--online" ]] && ONLINE=1

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
# Paths in messages are relative to this repo, which is where you run it.
rel() { echo "${1#"$GITOPS_ROOT/"}"; }

# Cluster identity agrees with the files that hard-code it.
for cluster in "${LFI_CLUSTERS[@]}"; do
  [[ -d "argocd/apps-$cluster" ]] || fail "missing argocd/apps-$cluster"
  [[ -d "terraform/$cluster" ]] || fail "missing terraform/$cluster"
done
k3d_name="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"
cfg_name="$(yq '.metadata.name' terraform/local/01-cluster/k3d-config.yaml)"
[[ "$k3d_name" == "$cfg_name" ]] || fail "registry says the k3d cluster is '$k3d_name' but k3d-config.yaml says '$cfg_name'"

# Every profile says what a team may override, with a type, and uses each key
# in its templatePatch. A key listed but not used would be accepted and do
# nothing; a key used but not listed would be rejected for every team.
for pf in "$PROFILES"/*.yaml; do
  [[ -f "$pf" ]] || { fail "no profiles in $(rel "$PROFILES")"; break; }
  p="$(rel "$pf")"
  for key in $(yq '.overridable | keys | .[]' "$pf"); do
    type="$(K="$key" yq '.overridable[strenv(K)]' "$pf")"
    [[ "$type" == string || "$type" == boolean ]] || fail "$p: overridable $key has type '$type', expected string or boolean"
    yq '.templatePatch' "$pf" | grep -q "\"overrides\" \"$key\"" || fail "$p: overridable $key is not used in templatePatch"
  done
done

# Names ArgoCD will make from an identity must be valid Kubernetes names, and
# short enough to be label values: 63 characters, lowercase letters, digits and
# dashes. The longest is <cluster>-<identity> or <env>-<identity>.
dns_ok() { [[ ${#1} -le 63 && "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }

# Every subscription is well formed, sits in the directory of a known cluster,
# is named after its identity, and names a profile that exists and a config
# repository the teams project trusts.
for sf in $(subscription_files); do
  f="$(rel "$sf")"
  cluster="$(basename "$(dirname "$sf")")"
  id="$(basename "$sf" .yaml)"
  [[ " ${LFI_CLUSTERS[*]} " == *" $cluster "* ]] || fail "$f is under '$cluster', which is not a cluster in the registry"
  for key in name team profile configRepo; do
    v="$(K="$key" yq '.[strenv(K)]' "$sf")"
    [[ -n "$v" && "$v" != null ]] || fail "$f has no '$key'"
  done
  team="$(yq '.team' "$sf")"; name="$(yq '.name' "$sf")"
  [[ "$id" == "$team-$name" ]] || fail "$f: the file must be named <team>-<name>.yaml, so $team-$name.yaml"
  dns_ok "$cluster-$id" || fail "$f: '$cluster-$id' is not a valid name of 63 characters or fewer"
  profile="$(yq '.profile' "$sf")"
  [[ -f "$(profile_file "$profile")" ]] || fail "$f: profile '$profile' does not exist under platform/profiles/"
  url="$(yq '.configRepo' "$sf")"
  [[ "$url" =~ ^https://github\.com/$OWNER/[A-Za-z0-9._-]+-config\.git$ ]] \
    || fail "$f: configRepo is $url; it must be https://github.com/$OWNER/<name>-config.git"
  path="$(yq '.repoPath // ""' "$sf")"
  [[ -z "$path" || "$path" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
    || fail "$f: repoPath '$path' must be a relative directory, with no leading or trailing slash"
  for dep in $(yq '.dependsOn[]?' "$sf"); do
    [[ " ${LFI_SERVICES[*]} " == *" $dep "* ]] || fail "$f: dependsOn $dep, which has no subscription"
    # A service calls its dependency inside its own cluster, so the dependency
    # must be subscribed on that cluster too, not merely somewhere.
    service_on_cluster "$dep" "$cluster" || fail "$f: dependsOn $dep, which is not subscribed on the $cluster cluster"
  done
done

# A service says the same thing about itself on every cluster it is on, or the
# clusters would run different things under one name by accident.
for svc in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
  for key in team profile configRepo repoPath; do
    n="$(for f in "$SUBSCRIPTIONS"/*/"$svc".yaml; do
      K="$key" yq '.[strenv(K)] // ""' "$f"
    done | sort -u | wc -l | tr -d ' ')"
    [[ "$n" == 1 ]] || fail "$svc is subscribed with $n different $key values"
  done
done

# Two services in one repository must not share a directory or sit inside one
# another: the outer one's environments would include the inner one's.
pairs="$(for svc in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
  echo "$(service_config_url "$svc")|$(service_repo_path "$svc")|$svc"
done)"
while IFS='|' read -r url_a path_a svc_a; do
  [[ -n "$svc_a" ]] || continue
  while IFS='|' read -r url_b path_b svc_b; do
    [[ -n "$svc_b" && "$svc_a" < "$svc_b" && "$url_a" == "$url_b" ]] || continue
    # The repository root (no repoPath) contains every other path in it.
    if [[ -z "$path_a" || -z "$path_b" || "$path_a" == "$path_b" \
          || "$path_b/" == "$path_a/"* || "$path_a/" == "$path_b/"* ]]; then
      fail "$svc_a and $svc_b share $url_a at overlapping paths ('${path_a:-the root}', '${path_b:-the root}')"
    fi
  done <<< "$pairs"
done <<< "$pairs"

# Manifests under argocd/ repeat the GitOps repo's URL because ArgoCD cannot
# read the registry. A repoURL naming this owner's repositories must be either
# that URL or a config repository; chart repositories are ignored.
want_url="https://github.com/$OWNER/$(yq '.repo' "$REGISTRY").git"
for f in $(find argocd -name '*.yaml' 2>/dev/null); do
  while IFS= read -r url; do
    [[ "$url" == "$want_url" || "$url" == *-config.git ]] || fail "$f names repoURL $url, registry says $want_url"
  done < <(yq '.. | select(has("repoURL")) | .repoURL' "$f" 2>/dev/null | grep '\.git$' | grep -v '{{' || true)
done

if [[ "$ONLINE" -eq 1 ]]; then
  work="$(mktemp -d)"
  # One shallow clone per repository, however many services share it.
  for url in $(for svc in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do service_config_url "$svc"; done | sort -u); do
    # No credential prompt: a repository that does not exist asks for a login.
    if ! GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q --depth 1 "$url" "$work/$(basename "$url" .git)" 2>/dev/null; then
      fail "config repository $url cannot be reached"
    fi
  done
  for svc in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
    url="$(service_config_url "$svc")"
    dir="$work/$(basename "$url" .git)"
    [[ -d "$dir" ]] || continue
    p="$(service_repo_path "$svc")"; dir="$dir${p:+/$p}"
    profile="$(service_profile "$svc")"; pf="$(profile_file "$profile")"
    for cluster in "${LFI_CLUSTERS[@]}"; do
      service_on_cluster "$svc" "$cluster" || continue
      found=0
      for env_file in "$dir/$cluster"/*/env.yaml; do
        [[ -f "$env_file" ]] || continue
        found=1
        rel="${env_file#"$work/"}"
        env="$(yq '.env // ""' "$env_file")"
        [[ -n "$env" ]] || fail "$rel has no 'env'"
        dns_ok "$env-$svc" || fail "$rel: '$env-$svc' is not a valid name of 63 characters or fewer"
        # Only the keys the profile allows, each with the type it says.
        for key in $(yq '.overrides // {} | keys | .[]' "$env_file"); do
          want="$(K="$key" yq '.overridable[strenv(K)] // ""' "$pf")"
          if [[ -z "$want" ]]; then
            fail "$rel: override '$key' is not allowed by profile $profile (allowed: $(yq '.overridable | keys | join(", ")' "$pf"))"
          else
            got="$(K="$key" yq '.overrides[strenv(K)] | type' "$env_file")"
            case "$want:$got" in
              string:!!str|boolean:!!bool) ;;
              *) fail "$rel: override '$key' must be a $want" ;;
            esac
          fi
        done
        # The environment renders, as ArgoCD will render it (remote components
        # included). And a database under a profile that prunes would be deleted
        # the first time its directory changed: profiles that prune hold no volumes.
        if ! kustomize build "$(dirname "$env_file")" > "$work/render.yaml" 2>"$work/render.err"; then
          fail "$(dirname "$rel") does not build: $(head -1 "$work/render.err")"
        elif [[ "$(yq '.template.spec.syncPolicy.automated.prune' "$pf")" == true ]] \
             && yq 'select(.kind == "StatefulSet" and (.spec.volumeClaimTemplates | length) > 0) | .metadata.name' \
                  "$work/render.yaml" | grep -q .; then
          fail "$rel: holds a StatefulSet with a volume, but $svc's profile ($profile) prunes. Use db-service."
        fi
      done
      [[ "$found" -eq 1 ]] || fail "$svc has no environments under ${p:+$p/}$cluster/ in $url"
    done
    # A releasable service has its team's deny list beside its environments.
    if service_releasable "$svc" && [[ ! -f "$dir/denied-builds.yaml" ]]; then
      fail "$svc has no ${p:+$p/}denied-builds.yaml in $url"
    fi
  done
  rm -rf "$work"
fi

# The ApplicationSets and the teams project are generated from the registry,
# the profiles and the subscriptions. Regenerate into a temporary directory and
# compare, so a hand edit, a new subscription without its set, or a set left
# behind by a removed subscription is caught. Only once the generator exists
# (Phase 20.2) and only once the sets have been put in place (Task 20.3.6).
#
# compare_generated <dir>: the committed sets and project against a fresh run.
compare_generated() {
  local gen="$1" cluster dir g id f
  for cluster in "${LFI_CLUSTERS[@]}"; do
    dir="argocd/apps-$cluster/appsets/subscriptions"
    if [[ -d "$dir" ]]; then
      # Every set the generator writes is in place and unchanged.
      for g in "$gen/$cluster-"*.yaml; do
        [[ -f "$g" ]] || continue
        id="$(basename "$g" .yaml)"; id="${id#"$cluster-"}"
        if [[ ! -f "$dir/$id.yaml" ]]; then
          fail "$dir/$id.yaml is missing. Regenerate: scripts/gen-appsets.sh"
        elif ! diff -q "$dir/$id.yaml" "$g" >/dev/null; then
          fail "$dir/$id.yaml differs from scripts/gen-appsets.sh. Regenerate it: scripts/gen-appsets.sh"
        fi
      done
      # And nothing is in place that the generator would not write.
      for f in "$dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        [[ -f "$gen/$cluster-$(basename "$f")" ]] \
          || fail "$f belongs to no subscription. Regenerate (scripts/gen-appsets.sh) to remove it"
      done
    fi
    f="argocd/apps-$cluster/projects/teams.yaml"
    if [[ -f "$f" ]] && ! diff -q "$f" "$gen/teams-$cluster.yaml" >/dev/null; then
      fail "$f differs from scripts/gen-appsets.sh. Regenerate it: scripts/gen-appsets.sh"
    fi
  done
}
if [[ -x "$SCRIPT_DIR/gen-appsets.sh" ]]; then
  gen="$(mktemp -d)"; trap 'rm -rf "$gen"' EXIT
  if "$SCRIPT_DIR/gen-appsets.sh" "$gen" >/dev/null 2>&1; then
    compare_generated "$gen"
  else
    fail "scripts/gen-appsets.sh cannot run. Fix the problems above first."
  fi
fi

if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS problem(s). The repo and its registry, profiles or subscriptions disagree." >&2
  exit 1
fi
echo "OK: ${#LFI_SERVICES[@]} service(s) x ${#LFI_CLUSTERS[@]} cluster(s) match the registry."
