#!/usr/bin/env bash
# Opens a PR that rolls one prod service back to an earlier image tag.
#
# Usage: scripts/rollback.sh <service> <to>
#   <service>  service-1 or service-2
#   <to>       what to go back to, in any of three forms:
#                a build name     26W39B2
#                a release name   2026-W38  or  2026-W40-B3
#                a commit hash    7e25e45 (prod's tag as of that commit)
#
# A rollback is a Git commit, like every other change here: it sets newTag in
# the prod overlay back to an older value and ArgoCD does the rest. The change
# goes through a PR, so the prod gate (CODEOWNERS) still applies.
#
# It does not touch releases/denied-builds.yaml. See the warning printed at the
# end: until dev moves on, the next `gmake release` promotes the same build again.
set -euo pipefail

SERVICES=(service-1 service-2)
# Prod overlay trees to roll back. Add `eks` here once the EKS cluster exists
# and kubernetes/overlays/eks/prod is in use.
TREES=(local)

SVC="${1:-}"
TO="${2:-}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

prod_file() { echo "kubernetes/overlays/$1/prod/$2/kustomization.yaml"; }

# The tag a file holds at a given commit. Empty if the file does not exist there.
tag_at() { # <commit> <path> <service>
  git show "$1:$2" 2>/dev/null \
    | SVC="$3" yq '.images[] | select(.name == strenv(SVC)) | .newTag' 2>/dev/null || true
}

# Prod's tag for a service as of a commit, whichever layout the commit had.
# Commits before the restructure keep the overlay at kubernetes/overlays/prod,
# not kubernetes/overlays/local/prod, so try the current path and then that one.
prod_tag_at() { # <commit> <tree> <service>
  local t
  t="$(tag_at "$1" "$(prod_file "$2" "$3")" "$3")"
  if [[ -z "$t" && "$2" == "local" ]]; then
    t="$(tag_at "$1" "kubernetes/overlays/prod/$3/kustomization.yaml" "$3")"
  fi
  echo "$t"
}

# Prod tags this service has had, newest first, deduplicated. Used for hints and
# to check that a named build really existed.
recent_tags() { # <service> [count]
  local svc="$1" count="${2:-5}" c
  git log --format=%H -n 60 -- "$(prod_file "${TREES[0]}" "$svc")" \
      "kubernetes/overlays/prod/$svc/kustomization.yaml" | while read -r c; do
    prod_tag_at "$c" "${TREES[0]}" "$svc"
  done | awk 'NF && !seen[$0]++' | head -n "$count"
}

recent_releases() { # [count]
  # --no-merges: a merge commit's body repeats the PR title, which would list
  # "Merge pull request ..." lines. Only the release commits themselves count.
  git log main --no-merges --format='%s' -n 200 \
    | grep '^release(prod): ' | sed 's/^release(prod): //' | awk '!seen[$0]++' | head -n "${1:-5}"
}

usage() {
  {
    echo "ERROR: $1"
    echo
    echo "  Usage:  gmake rollback SVC=service-1 TO=<build | release | commit>"
    echo
    echo "  TO can be:"
    echo "    a build name     26W39B2"
    echo "    a release name   2026-W38, or 2026-W40-B3 for a build-named release"
    echo "    a commit hash    7e25e45   (prod's tag as of that commit)"
    echo
    if [[ -n "$SVC" && " ${SERVICES[*]} " == *" $SVC "* ]]; then
      echo "  Recent prod tags for $SVC:"
      recent_tags "$SVC" 5 | sed 's/^/    /'
      echo
    fi
    echo "  Recent releases:"
    recent_releases 5 | sed 's/^/    /'
  } >&2
  exit 1
}

if [[ -z "$SVC" ]]; then usage "SVC is required: the service to roll back."; fi
if [[ " ${SERVICES[*]} " != *" $SVC "* ]]; then
  usage "SVC must be one of: ${SERVICES[*]} (got '$SVC')."
fi
if [[ -z "$TO" ]]; then usage "TO is required: the build, release or commit to go back to."; fi

# Refuse a dirty tree, for the same reason release.sh does: a rollback commit
# that quietly carries an unrelated change is the surprise this process avoids.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

git switch main >/dev/null 2>&1
git pull --ff-only
git fetch --quiet --prune origin

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
  MATCHES="$(git log main --no-merges --format=%h --grep="^release(prod): ${TO}\$")"
  COUNT="$(printf '%s\n' "$MATCHES" | grep -c . || true)"
  if [[ "$COUNT" -eq 0 ]]; then
    usage "no release named '$TO'."
  fi
  COMMIT="$(printf '%s\n' "$MATCHES" | head -n 1)"
  if [[ "$COUNT" -gt 1 ]]; then
    echo "NOTE: $COUNT commits are named 'release(prod): $TO'. Using the newest ($COMMIT)." >&2
    echo "      Pass a commit hash instead to pick a different one." >&2
  fi
elif [[ "$TO" =~ ^[0-9a-f]{7,40}$ ]]; then
  KIND="commit"
  COMMIT="$(git rev-parse --verify --quiet "${TO}^{commit}")" \
    || usage "'$TO' is not a commit in this repository."
  COMMIT="$(git rev-parse --short "$COMMIT")"
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

# --- Resolve to a tag, per tree. Old commits predate overlays/local, so fall
# back to the pre-restructure path. ---
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
      dev_file="kubernetes/overlays/$tree/dev/$SVC/kustomization.yaml"
      if ! git log -S"newTag: ${to}" --format=%h -- "$dev_file" "$file" \
            "kubernetes/overlays/dev/$SVC/kustomization.yaml" "kubernetes/overlays/prod/$SVC/kustomization.yaml" | grep -q .; then
        usage "build '$to' never appears in $SVC's history."
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
echo "Rollback $SVC in prod:"
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
echo
if [[ "${ASSUME_YES:-}" != "1" ]]; then
  read -r -p "Open the rollback PR? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled. Nothing changed."; exit 1; }
fi

# --- Branch, edit, commit, push, PR. ---
FIRST_TO="${PLAN[0]##*|}"
BASE_BRANCH="rollback/${SVC}-${FIRST_TO}"
BRANCH="$BASE_BRANCH"
n=2
while git show-ref --verify --quiet "refs/heads/${BRANCH}" \
   || git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do
  BRANCH="${BASE_BRANCH}-${n}"
  n=$((n + 1))
done
git switch -c "$BRANCH"

BODY="## Rollback ${SVC}"$'\n\n'"| Tree | From | To |"$'\n'"|---|---|---|"$'\n'
for entry in "${PLAN[@]}"; do
  IFS='|' read -r tree file from to <<< "$entry"
  yq -i '(.images[] | select(.name == "'"$SVC"'") | .newTag) = "'"$to"'"' "$file"
  git add "$file"
  BODY+="| \`$tree\` | \`$from\` | \`$to\` |"$'\n'
done
BODY+=$'\n'"Asked for: \`${TO}\` (${ASKED})"$'\n\n'
BODY+="**This does not deny the build it replaces.** Until dev moves past it, the next"$'\n'
BODY+="\`gmake release\` promotes the same build again. After merging, the prod canary"$'\n'
BODY+="pauses at 50 percent like any release: \`gmake canary-promote SVC=${SVC}\`."

FROM_TAG="$(echo "${PLAN[0]}" | cut -d'|' -f3)"
git commit -m "rollback(prod): ${SVC} ${FROM_TAG} -> ${FIRST_TO}"
git push -u origin "$BRANCH"

gh pr create --title "rollback(prod): ${SVC} ${FROM_TAG} -> ${FIRST_TO}" --body "$BODY" --base main

git switch main
echo
echo "Rollback PR opened. Review the diff, then merge it."
echo "WARNING: ${FROM_TAG} is not on the deny list. Until dev moves past it, the next"
echo "         gmake release will promote it again. Add it to releases/denied-builds.yaml"
echo "         if it must never ship."
echo "After merging, the canary pauses at 50 percent: gmake canary-promote SVC=${SVC}"
