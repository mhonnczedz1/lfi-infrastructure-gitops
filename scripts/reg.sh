# Reads platform/registry.yaml, platform/subscribers.yaml and the profiles in the
# templates repository. Sourced by other scripts, never run directly. Written for
# bash 3.2 (macOS): no mapfile and no associative arrays.
# bash sets BASH_SOURCE; zsh (an interactive shell here) sets $0 to the sourced file.
_reg_src="${BASH_SOURCE[0]:-$0}"
GITOPS_ROOT="$(cd "$(dirname "$_reg_src")/.." && pwd)"
REGISTRY="${REGISTRY:-$GITOPS_ROOT/platform/registry.yaml}"
SUBSCRIBERS="${SUBSCRIBERS:-$GITOPS_ROOT/platform/subscribers.yaml}"

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
#
# They live in the templates repository, beside the components and scaffolds,
# and the registry pins the tag to read them at (profilesRef). The first script
# that needs them fetches that tag into .tmp/profiles-<tag>/, which later runs
# reuse: a tag is a release and does not move. PROFILES=<dir> uses a local copy
# instead, for working offline or trying a profile change before it is tagged.
PROFILES_REF="$(yq '.profilesRef // ""' "$REGISTRY")"
TEMPLATES_URL="${TEMPLATES_URL:-https://github.com/$OWNER/$PROJECT-service-templates}"
PROFILES_ERROR=""
if [[ -z "${PROFILES:-}" ]]; then
  PROFILES="$GITOPS_ROOT/.tmp/profiles-$PROFILES_REF"
  if [[ -z "$PROFILES_REF" ]]; then
    PROFILES_ERROR="platform/registry.yaml has no profilesRef"
  elif [[ ! -d "$PROFILES" ]]; then
    _tmp="$(mktemp -d)"
    if GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone -q --depth 1 --branch "$PROFILES_REF" \
         "$TEMPLATES_URL.git" "$_tmp/t" 2>/dev/null && [[ -d "$_tmp/t/profiles" ]]; then
      mkdir -p "$(dirname "$PROFILES")" && cp -R "$_tmp/t/profiles" "$PROFILES"
    else
      PROFILES_ERROR="cannot read profiles/ at $PROFILES_REF from $TEMPLATES_URL"
    fi
    rm -rf "$_tmp"
  fi
fi
[[ -z "$PROFILES_ERROR" ]] || echo "WARNING: $PROFILES_ERROR. Commands that need a profile will fail." >&2

profile_file() { echo "$PROFILES/$1.yaml"; }
profile_field() { # <profile> <yq path>, empty if unset
  local f v
  f="$(profile_file "$1")"
  [[ -f "$f" ]] || return 0
  v="$(yq "$2" "$f")"
  [[ "$v" == null ]] && v=""
  echo "$v"
}

# --- Services come from platform/subscribers.yaml, not from the registry. ---
#
# One entry per subscription. A service's identity is <team>-<name>, and its
# clusters list says where it runs, so nothing is repeated per cluster and
# nothing needs to split a name apart.

# The yq selector for one identity's entry.
_sub() { echo '.subscribers[] | select(.team + "-" + .name == strenv(I))'; }

# Every identity, once each, in name order.
LFI_SERVICES=()
while IFS= read -r _i; do
  [[ -n "$_i" ]] && LFI_SERVICES+=("$_i")
done < <(yq '.subscribers[]? | .team + "-" + .name' "$SUBSCRIBERS" 2>/dev/null | sort -u)

service_field() { # <identity> <yq path>, empty if unset
  local v
  v="$(I="$1" yq "$(_sub) | $2" "$SUBSCRIBERS")"
  [[ "$v" == null ]] && v=""
  echo "$v"
}
service_team()        { service_field "$1" .team; }
service_profile()     { service_field "$1" .profile; }
service_description() { service_field "$1" .description; }
service_config_url()  { service_field "$1" .configRepo; }
service_repo_path()   { service_field "$1" .repoPath; }
# The clusters a service runs on, one per line.
service_clusters()    { I="$1" yq "$(_sub) | .clusters[]?" "$SUBSCRIBERS"; }
# Is this identity subscribed on this cluster?
service_on_cluster() { [[ " $(service_clusters "$1" | tr '\n' ' ') " == *" $2 "* ]]; }
# The identities subscribed on a cluster, in name order.
cluster_services() {
  local s
  for s in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
    service_on_cluster "$s" "$1" && echo "$s"
  done
  return 0
}
# Services that <identity> calls.
service_deps() { I="$1" yq "$(_sub) | .dependsOn[]?" "$SUBSCRIBERS"; }
# Services that call <identity>.
service_dependents() {
  local s
  for s in ${LFI_SERVICES[@]+"${LFI_SERVICES[@]}"}; do
    [[ " $(service_deps "$s" | tr '\n' ' ') " == *" $1 "* ]] && echo "$s"
  done
  return 0
}

# The stages a build moves through, in order, one per line. A team declares
# them in its subscription as a list, promotion: [dev, staging, prod]; the
# default is [dev, prod]. CI writes the first stage; a release moves a build one
# step, into a stage from the stage before it.
promotion_stages() {
  local v
  v="$(service_field "$1" '.promotion[]?')"
  if [[ -n "$v" ]]; then echo "$v"; else printf 'dev\nprod\n'; fi
}
promote_first() { promotion_stages "$1" | head -n 1; } # <identity>: where CI writes
# promote_to <identity> [stage]: the stage a release moves into. The one named
# if it is a stage after the first, the last stage if none is named, and a
# failure otherwise.
promote_to() {
  local stages
  stages="$(promotion_stages "$1")"
  if [[ -z "${2:-}" ]]; then echo "$stages" | tail -n 1; return 0; fi
  echo "$stages" | tail -n +2 | grep -qx "$2" || return 1
  echo "$2"
}
# promote_from <identity> [stage]: the stage just before promote_to's.
promote_from() {
  local to
  to="$(promote_to "$1" "${2:-}")" || return 1
  promotion_stages "$1" | grep -x -B1 "$to" | head -n 1
}

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
