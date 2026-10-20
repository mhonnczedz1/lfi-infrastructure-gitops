#!/usr/bin/env bash
# Opens a PR that rolls one prod service back to an earlier image tag.
#
# Usage: scripts/rollback.sh [<service> [<to>]]
#   With no arguments it asks, in a terminal: which cluster (local or eks), which
#   service, what to go back to (a numbered list of recent builds, or type one),
#   then asks to confirm. Anything you pass skips that question:
#     gmake rollback CLUSTER=eks SVC=team-1-service-1 TO=26W39B2
#   Without a terminal, a missing argument is an error with a hint, never a prompt.
#   One cluster per rollback: whether to go back is a per-cluster judgment.
#   <service>  a released service's identity (gmake status lists them)
#   <to>       what to go back to, in any of three forms:
#                a build name     26W39B2
#                a release name   2026-W38  or  2026-W40-B3
#                a commit hash    7e25e45 (prod's tag as of that commit)
#
# A rollback is a Git commit, like every other change here: it sets newTag in
# the prod environment of the service's config repository back to an older value
# and ArgoCD does the rest. The change goes through a PR in that repository, so
# the team's own review rules still apply.
#
# It does not touch the service's denied-builds.yaml. See the warning printed at
# the end: until dev moves on, the next `gmake release` promotes the same build
# again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SERVICES=(${LFI_RELEASABLE[@]+"${LFI_RELEASABLE[@]}"})
# The prod overlay tree to roll back, named after the cluster. Replaced below by
# the cluster you choose. local until then, so the hints in usage() have something
# to show if an argument is wrong before the question is reached.
TREES=(local)

SVC="${1:-${SVC:-}}"
TO="${2:-${TO:-}}"

cd "$SCRIPT_DIR/.."

# The config repository of the service being rolled back. Set once the service
# is chosen, below. Every Git command in this script goes through cfg_git.
CFG=""
cfg_git() { git -C "$CFG" "$@"; }

# Where, inside the config repo, a cluster's prod environment keeps its tag:
# <repoPath>/<cluster>/<to>/kustomization.yaml.
prod_file() { echo "$(service_prefix "$2")$1/$(promote_to "$2")/kustomization.yaml"; } # <tree> <service>

# The tag a file holds at a given commit. Empty if the file does not exist there.
tag_at() { # <commit> <path>
  cfg_git show "$1:$2" 2>/dev/null | yq '.images[0].newTag // ""' 2>/dev/null || true
}

# Prod's tag for a service as of a commit.
prod_tag_at() { # <commit> <tree> <service>
  tag_at "$1" "$(prod_file "$2" "$3")"
}

# Prod tags this service has had, newest first, deduplicated. Used for hints and
# to check that a named build really existed.
recent_tags() { # <service> [count]
  local svc="$1" count="${2:-5}" c
  cfg_git log --format=%H -n 60 -- "$(prod_file "${TREES[0]}" "$svc")" | while read -r c; do
    prod_tag_at "$c" "${TREES[0]}" "$svc"
  done | awk 'NF && !seen[$0]++' | head -n "$count"
}

recent_releases() { # <service> [count]
  # --no-merges: a merge commit's body repeats the PR title, which would list
  # "Merge pull request ..." lines. Only the release commits themselves count.
  # A release title is "release(<env>): <service> <name>", and a shared repo
  # holds other services' releases too, so only this service's are kept. The
  # name is what follows the service, without the partial-release scope
  # (" [local / ...]") or the " (#12)" that a squash merge appends.
  [[ -n "$CFG" ]] || return 0
  cfg_git log main --no-merges --format='%s' -n 200 \
    | grep "^release([a-z0-9-]*): $1 " \
    | sed -e 's/^release([a-z0-9-]*): [^ ]* //' -e 's/ (#[0-9]*)$//' -e 's/ \[.*$//' \
    | awk '!seen[$0]++' | head -n "${2:-5}"
}

usage() {
  {
    echo "ERROR: $1"
    echo
    echo "  Usage:  gmake rollback CLUSTER=local SVC=<service> TO=<build | release | commit>"
    echo
    echo "  TO can be:"
    echo "    a build name     26W39B2"
    echo "    a release name   2026-W38, or 2026-W40-B3 for a build-named release"
    echo "    a commit hash    7e25e45   (prod's tag as of that commit)"
    echo
    if [[ -n "$SVC" && -n "$CFG" && " ${SERVICES[*]-} " == *" $SVC "* ]]; then
      echo "  Recent prod tags for $SVC:"
      recent_tags "$SVC" 5 | sed 's/^/    /'
      echo
      echo "  Recent releases of $SVC:"
      recent_releases "$SVC" 5 | sed 's/^/    /'
    fi
  } >&2
  exit 1
}

# Interactive when a person is at the keyboard (stdin is a terminal). With
# SVC and TO both given it behaves exactly as before, and in a pipe or CI with
# either missing it still fails with the usage hint instead of waiting forever.
INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1

# Cluster first, since the prod tags, the history and the PR all belong to one.
pick_cluster "roll back" no "running"
TREES=("${PICKED_CLUSTERS[0]}")
CLUSTER_NAME="${TREES[0]}"
pick_service "roll back" no
SVC="${PICKED_SERVICES[0]}"

service_on_cluster "$SVC" "$CLUSTER_NAME" || { echo "ERROR: $SVC is not subscribed on $CLUSTER_NAME." >&2; exit 1; }
CFG="$(service_config_dir "$SVC")"
[[ -d "$CFG/.git" ]] || { echo "ERROR: $SVC's config repo is not checked out at $CFG." >&2; exit 1; }

# Refuse a dirty tree, for the same reason release.sh does: a rollback commit
# that quietly carries an unrelated change is the surprise this process avoids.
if [[ -n "$(cfg_git status --porcelain)" ]]; then
  echo "ERROR: $CFG has uncommitted changes. Commit or stash first." >&2
  exit 1
fi

# Before any prompt, so the "prod is on ..." and recent-builds lists reflect main.
cfg_git switch main >/dev/null 2>&1
cfg_git pull --ff-only --quiet
cfg_git fetch --quiet --prune origin

if [[ -z "$TO" ]]; then
  if [[ "$INTERACTIVE" -ne 1 ]]; then usage "TO is required: the build, release or commit to go back to."; fi
  CURRENT="$(prod_tag_at HEAD "${TREES[0]}" "$SVC")"
  echo
  echo "$SVC prod is on ${CURRENT:-?}. Roll back to which build?"
  # Recent prod tags other than the one running, numbered so a digit picks one.
  declare -a CHOICES=()
  while IFS= read -r t; do
    [[ -n "$t" && "$t" != "$CURRENT" ]] && CHOICES+=("$t")
  done < <(recent_tags "$SVC" 8)
  i=1
  for t in "${CHOICES[@]}"; do
    printf '  %d) %s\n' "$i" "$t"
    i=$((i + 1))
  done
  echo
  echo "  Or type a build name, a release name (recent: $(recent_releases "$SVC" 3 | paste -sd ',' - | sed 's/,/, /g')),"
  echo "  or a commit hash."
  read -r -p "Roll back to (Enter to cancel): " choice
  [[ -n "$choice" ]] || { echo "Cancelled. Nothing changed."; exit 1; }
  if [[ "$choice" =~ ^[0-9]{1,2}$ && "$choice" -ge 1 && "$choice" -le ${#CHOICES[@]} ]]; then
    TO="${CHOICES[$((choice - 1))]}"
  else
    TO="$choice"
  fi
  EQUIV+=" TO=${TO}"
fi

# --- Work out which commit (if any) TO names, and what kind of input it is. ---
KIND=""
COMMIT=""
if [[ "$TO" =~ ^[0-9]{2}W[0-9]{2}B[0-9]+$ ]]; then
  KIND="build"
elif [[ "$TO" =~ ^[0-9]{4}-W[0-9]{2}(-B[0-9]+)?(-[0-9]+)?$ ]]; then
  KIND="release"
  # A release name can match more than one commit: this repo has reused a
  # release branch within a week. Take the newest, which is the week's final
  # state, and say so.
  MATCHES="$(cfg_git log main --no-merges -E --format=%h --grep="^release\([a-z0-9-]*\): ${SVC} ${TO}( \[[^]]*\])?( \(#[0-9]+\))?\$")"
  COUNT="$(printf '%s\n' "$MATCHES" | grep -c . || true)"
  if [[ "$COUNT" -eq 0 ]]; then
    usage "no release of $SVC named '$TO'."
  fi
  COMMIT="$(printf '%s\n' "$MATCHES" | head -n 1)"
  if [[ "$COUNT" -gt 1 ]]; then
    echo "NOTE: $COUNT commits are named 'release(prod): $SVC $TO'. Using the newest ($COMMIT)." >&2
    echo "      Pass a commit hash instead to pick a different one." >&2
  fi
elif [[ "$TO" =~ ^[0-9a-f]{7,40}$ ]]; then
  KIND="commit"
  COMMIT="$(cfg_git rev-parse --verify --quiet "${TO}^{commit}")" \
    || usage "'$TO' is not a commit in $SVC's config repository."
  COMMIT="$(cfg_git rev-parse --short "$COMMIT")"
else
  usage "'$TO' is not a build name, a release name or a commit hash."
fi

# How to describe the request in output: "build", "release, commit abc1234",
# or "commit abc1234".
case "$KIND" in
  build)   ASKED="build" ;;
  release) ASKED="release, commit ${COMMIT}" ;;
  commit)  ASKED="commit ${COMMIT}" ;;
esac

# --- Resolve to a tag, per tree. ---
declare -a PLAN=()   # tree|file|from|to
for tree in "${TREES[@]}"; do
  file="$(prod_file "$tree" "$SVC")"
  from="$(prod_tag_at HEAD "$tree" "$SVC")"
  if [[ -z "$from" ]]; then
    echo "ERROR: cannot read the current tag from $file." >&2
    exit 1
  fi

  if [[ "$KIND" == "build" ]]; then
    to="$TO"
    # The build must have existed in this overlay's history, or a typo would
    # point prod at an image that was never built.
    if ! recent_tags "$SVC" 40 | grep -qx "$to"; then
      # It may have only ever run in dev, so check there too.
      dev_file="$(service_prefix "$SVC")$tree/$(promote_from "$SVC")/kustomization.yaml"
      if ! cfg_git log -S"newTag: ${to}" --format=%h -- "$dev_file" "$file" | grep -q .; then
        usage "build '$to' never appears in $SVC's config repository history. History from before the move to config repositories stays in the GitOps repository: for a build from then, edit the tag by hand in a PR."
      fi
    fi
  else
    to="$(prod_tag_at "$COMMIT" "$tree" "$SVC")"
    if [[ -z "$to" ]]; then
      echo "ERROR: $SVC has no prod tag at commit $COMMIT." >&2
      exit 1
    fi
  fi
  PLAN+=("$tree|$file|$from|$to")
done

# Nothing to do if every tree is already there.
ALREADY=1
for entry in "${PLAN[@]}"; do
  IFS='|' read -r tree file from to <<< "$entry"
  [[ "$from" != "$to" ]] && ALREADY=0
done
if [[ "$ALREADY" -eq 1 ]]; then
  IFS='|' read -r tree file from to <<< "${PLAN[0]}"
  echo "Nothing to do: $SVC prod is already at $to."
  exit 0
fi

# --- Show what will happen, and ask. ---
echo
echo "Rollback ${SVC} in prod on ${CLUSTER_NAME}:"
for entry in "${PLAN[@]}"; do
  IFS='|' read -r tree file from to <<< "$entry"
  echo "  $tree   $from  ->  $to"
  # sort -V puts 26W40B10 after 26W40B9. If the target sorts later, this is a
  # roll-forward and the person should know.
  if [[ "$(printf '%s\n%s\n' "$from" "$to" | sort -V | tail -n 1)" == "$to" && "$from" != "$to" ]]; then
    echo "  NOTE: $to is NEWER than $from, so this is a roll-forward, not a rollback."
  fi
done
echo "  asked for: $TO ($ASKED)"
show_equivalent "gmake rollback"
echo
confirm "Open the rollback PR?"

# --- Branch, edit, commit, push, PR. ---
FIRST_TO="${PLAN[0]##*|}"
BASE_BRANCH="rollback/${CLUSTER_NAME}-${SVC}-${FIRST_TO}"
BRANCH="$BASE_BRANCH"
n=2
while cfg_git show-ref --verify --quiet "refs/heads/${BRANCH}" \
   || cfg_git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do
  BRANCH="${BASE_BRANCH}-${n}"
  n=$((n + 1))
done
cfg_git switch -q -c "$BRANCH"

BODY="## Rollback ${CLUSTER_NAME}/${SVC}"$'\n\n'"| Tree | From | To |"$'\n'"|---|---|---|"$'\n'
for entry in "${PLAN[@]}"; do
  IFS='|' read -r tree file from to <<< "$entry"
  T="$to" yq -i '.images[0].newTag = strenv(T)' "$CFG/$file"
  cfg_git add "$file"
  BODY+="| \`$tree\` | \`$from\` | \`$to\` |"$'\n'
done
BODY+=$'\n'"Asked for: \`${TO}\` (${ASKED})"$'\n\n'
BODY+="**This does not deny the build it replaces.** Until dev moves past it, the next"$'\n'
BODY+="\`gmake release\` promotes the same build again. After merging, the prod canary"$'\n'
BODY+="pauses at 50 percent like any release: \`gmake canary\`."

FROM_TAG="$(echo "${PLAN[0]}" | cut -d'|' -f3)"
cfg_git commit -q -m "rollback(prod): ${CLUSTER_NAME}/${SVC} ${FROM_TAG} -> ${FIRST_TO}"
cfg_git push -q -u origin "$BRANCH"

(cd "$CFG" && gh pr create --title "rollback(prod): ${CLUSTER_NAME}/${SVC} ${FROM_TAG} -> ${FIRST_TO}" --body "$BODY" --base main)

cfg_git switch -q main
echo
echo "Rollback PR opened in $(basename "$CFG"). Review the diff, then merge it."
echo
echo "WARNING: ${FROM_TAG} is not on the deny list. Until dev moves past it, the next"
echo "         gmake release will promote it again. Add it to $(service_prefix "$SVC")denied-builds.yaml"
echo "         in $(basename "$CFG") if it must never ship."
next_steps "merge the PR           ArgoCD then starts a canary that pauses at 50 percent." \
           "gmake canary           promote it to finish the rollback on ${CLUSTER_NAME}." \
           "gmake status           confirm ${SVC} is back on ${FIRST_TO}"
