# Reads platform/registry.yaml, platform/profiles/ and platform/subscriptions/.
# Sourced by other scripts, never run directly. Written for bash 3.2 (macOS): no
# mapfile and no associative arrays.
# bash sets BASH_SOURCE; zsh (an interactive shell here) sets $0 to the sourced file.
_reg_src="${BASH_SOURCE[0]:-$0}"
GITOPS_ROOT="$(cd "$(dirname "$_reg_src")/.." && pwd)"
REGISTRY="${REGISTRY:-$GITOPS_ROOT/platform/registry.yaml}"
PROFILES="${PROFILES:-$GITOPS_ROOT/platform/profiles}"
SUBSCRIPTIONS="${SUBSCRIPTIONS:-$GITOPS_ROOT/platform/subscriptions}"

# registry_list '<yq expression>' fills REGISTRY_LIST, one array element per line.
registry_list() {
  REGISTRY_LIST=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && REGISTRY_LIST+=("$line")
  done < <(yq "$1" "$REGISTRY")
}

registry_list '.clusters[].name'; LFI_CLUSTERS=("${REGISTRY_LIST[@]}")
NAMESPACE_PREFIX="$(yq '.namespacePrefix' "$REGISTRY")"
PROJECT="$(yq '.project' "$REGISTRY")"
OWNER="$(yq '.owner' "$REGISTRY")"

# cluster_field <cluster> <field>: prints the value, or fails if there is none.
cluster_field() {
  local v
  v="$(C="$1" yq '.clusters[] | select(.name == strenv(C)) | .'"$2" "$REGISTRY")"
  [[ -n "$v" && "$v" != null ]] || return 1
  echo "$v"
}
cluster_context() { cluster_field "$1" context; }

# --- Profiles: what kinds of deployable unit the platform offers. ---

profile_file() { echo "$PROFILES/$1.yaml"; }
profile_field() { # <profile> <yq path>, empty if unset
  local f v
  f="$(profile_file "$1")"
  [[ -f "$f" ]] || return 0
  v="$(yq "$2" "$f")"
  [[ "$v" == null ]] && v=""
  echo "$v"
}

# --- Services come from subscriptions, not from the registry. ---
#
# A service's identity is <team>-<name>. Its subscription on a cluster is
# platform/subscriptions/<cluster>/<identity>.yaml, so the file name is the
# identity and nothing needs to split a name apart.

# subscription_files lists every subscription file, one per service per cluster.
subscription_files() { ls "$SUBSCRIPTIONS"/*/*.yaml 2>/dev/null || true; }

# Every identity any cluster subscribes to, once each, in name order.
LFI_SERVICES=()
while IFS= read -r _f; do
  [[ -n "$_f" ]] && LFI_SERVICES+=("$(basename "$_f" .yaml)")
done < <(subscription_files)
if [[ ${#LFI_SERVICES[@]} -gt 0 ]]; then
  LFI_SERVICES=($(printf '%s\n' "${LFI_SERVICES[@]}" | sort -u))
fi

# The first subscription file for this identity. Fields every cluster shares
# (team, profile, configRepo, repoPath, dependsOn, promotion) are read from it;
# the contract check fails if two clusters disagree about them.
service_file() {
  local f
  for f in "$SUBSCRIPTIONS"/*/"$1".yaml; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}
service_field() { # <identity> <yq path>, empty if unset
  local f v
  f="$(service_file "$1")" || return 0
  v="$(yq "$2" "$f")"
  [[ "$v" == null ]] && v=""
  echo "$v"
}
service_team()        { service_field "$1" .team; }
service_profile()     { service_field "$1" .profile; }
service_description() { service_field "$1" .description; }
service_config_url()  { service_field "$1" .configRepo; }
service_repo_path()   { service_field "$1" .repoPath; }
# Is this identity subscribed on this cluster?
service_on_cluster() { [[ -f "$SUBSCRIPTIONS/$2/$1.yaml" ]]; }
# Services that <identity> calls.
service_deps() { local f; f="$(service_file "$1")" || return 0; yq '.dependsOn[]?' "$f"; }
# Services that call <identity>.
service_dependents() {
  local s
  for s in "${LFI_SERVICES[@]}"; do
    [[ " $(service_deps "$s" | tr '\n' ' ') " == *" $1 "* ]] && echo "$s"
  done
  return 0
}

# The environment a release promotes from and to. A team declares it in its
# subscription; the default is dev to prod.
promote_from() { local v; v="$(service_field "$1" .promotion.from)"; echo "${v:-dev}"; }
promote_to()   { local v; v="$(service_field "$1" .promotion.to)";   echo "${v:-prod}"; }

# A releasable service is one whose profile says so (web-service): its
# environments carry an image tag that CI writes and gmake release moves. A
# database is not released; its manifests change by a commit like any other.
service_releasable() { [[ "$(profile_field "$(service_profile "$1")" .releasable)" == true ]]; }
LFI_RELEASABLE=()
for _s in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
  service_releasable "$_s" && LFI_RELEASABLE+=("$_s")
done

# Where the service's config repo is checked out on this machine: a sibling of
# this repo, named like the repo on GitHub. Several services may share one.
service_config_dir() {
  local url
  url="$(service_config_url "$1")"
  [[ -n "$url" ]] || return 1
  echo "$(dirname "$GITOPS_ROOT")/$(basename "$url" .git)"
}
# The service's own directory inside its config repo: the repo root, or repoPath.
service_dir() {
  local cfg p
  cfg="$(service_config_dir "$1")" || return 1
  p="$(service_repo_path "$1")"
  echo "$cfg${p:+/$p}"
}
# The same, relative to the repo root: "" or "<repoPath>/". For building paths
# that Git and the CI workflow use.
service_prefix() { local p; p="$(service_repo_path "$1")"; echo "${p:+$p/}"; }

# The environments a service has on a cluster: one directory per environment
# in its config repo, found by the env.yaml inside it.
service_envs() { # <identity> <cluster>
  local dir f
  dir="$(service_dir "$1")" || return 0
  for f in "$dir/$2"/*/env.yaml; do
    [[ -f "$f" ]] && basename "$(dirname "$f")"
  done
  return 0
}

# The Application ArgoCD generates for a service's environment.
app_name() { echo "$1-$2"; } # <env> <identity>
