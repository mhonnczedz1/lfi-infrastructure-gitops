# Reads platform/registry.yaml and platform/subscriptions/. Sourced by other
# scripts, never run directly. Written for bash 3.2 (macOS): no mapfile and no
# associative arrays.
# bash sets BASH_SOURCE; zsh (an interactive shell here) sets $0 to the sourced file.
_reg_src="${BASH_SOURCE[0]:-$0}"
GITOPS_ROOT="$(cd "$(dirname "$_reg_src")/.." && pwd)"
REGISTRY="${REGISTRY:-$GITOPS_ROOT/platform/registry.yaml}"
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

# --- Services come from subscriptions, not from the registry. ---

# subscription_files lists every subscription file, one per service per cluster.
subscription_files() { ls "$SUBSCRIPTIONS"/*/*.yaml 2>/dev/null || true; }

# The services any cluster subscribes to, once each, in name order.
LFI_SERVICES=()
while IFS= read -r _f; do
  [[ -n "$_f" ]] && LFI_SERVICES+=("$(yq '.name' "$_f")")
done < <(subscription_files)
if [[ ${#LFI_SERVICES[@]} -gt 0 ]]; then
  LFI_SERVICES=($(printf '%s\n' "${LFI_SERVICES[@]}" | sort -u))
fi

# The first subscription file that names this service. Fields every cluster
# shares (role, dependsOn, configRepo, promotion) are read from it.
service_file() {
  local f
  for f in $(subscription_files); do
    [[ "$(yq '.name' "$f")" == "$1" ]] && { echo "$f"; return 0; }
  done
  return 1
}
service_field() { # <service> <yq path>, empty if unset
  local f v
  f="$(service_file "$1")" || return 0
  v="$(yq "$2" "$f")"
  [[ "$v" == null ]] && v=""
  echo "$v"
}
service_role()       { service_field "$1" .role; }
service_config_url() { service_field "$1" .configRepo; }
# Services that <service> calls.
service_deps() { local f; f="$(service_file "$1")" || return 0; yq '.dependsOn[]?' "$f"; }
# Services that call <service>.
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

# Where the service's config repo is checked out on this machine: a sibling of
# this repo, named like the repo on GitHub.
service_config_dir() {
  local url
  url="$(service_config_url "$1")"
  [[ -n "$url" ]] || return 1
  echo "$(dirname "$GITOPS_ROOT")/$(basename "$url" .git)"
}

# The environments a service has on a cluster: one directory per environment
# in its config repo, found by the env.yaml inside it.
service_envs() { # <service> <cluster>
  local dir f
  dir="$(service_config_dir "$1")" || return 0
  for f in "$dir/$2"/*/env.yaml; do
    [[ -f "$f" ]] && basename "$(dirname "$f")"
  done
  return 0
}
