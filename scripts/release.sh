#!/usr/bin/env bash
# Opens the weekly prod release PR.
#
# Reads the image tags the dev overlay is currently running and writes them
# into the prod overlay. Nothing is built: the images already exist in GHCR and
# have been serving dev traffic all week. This script only moves a reference.
set -euo pipefail

SERVICES=(service-1 service-2)
# %G is the ISO week-numbering year, not the calendar year. They diverge at
# New Year: 2027-01-01 falls in ISO week 53 of 2026, so %Y-W%V would name that
# release 2027-W53, a week that does not exist. UTC to match CI.
WEEK="$(date -u +%G-W%V)"     # ISO week, so release/2026-W36
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Refuse to run from a dirty tree. A release commit that quietly carries an
# unrelated working change is exactly the kind of surprise this whole process
# exists to prevent.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

git switch main >/dev/null 2>&1
git pull --ff-only

DENYLIST="releases/denied-builds.yaml"
if [[ ! -f "$DENYLIST" ]]; then
  echo "ERROR: ${DENYLIST} is missing. Refusing to release without it." >&2
  exit 1
fi

# Collect what would change, before changing anything, so the script can decide
# whether there is a release to make and can build the PR body.
declare -a CHANGES=()
declare -a BLOCKED=()
for svc in "${SERVICES[@]}"; do
  dev_tag="$(yq '.images[] | select(.name == "'"$svc"'") | .newTag' \
    "kubernetes/overlays/local/dev/$svc/kustomization.yaml")"
  prod_tag="$(yq '.images[] | select(.name == "'"$svc"'") | .newTag' \
    "kubernetes/overlays/local/prod/$svc/kustomization.yaml")"

  [[ "$dev_tag" == "$prod_tag" ]] && continue

  # A denied build drops out of the release. It is never silently replaced
  # with an older one: shipping something other than what you asked for is
  # exactly the surprise this whole process exists to prevent. strenv reads
  # the values as strings so a numeric-looking tag is not coerced.
  reason="$(SVC="$svc" TAG="$dev_tag" yq '
    .denied[] | select(.service == strenv(SVC) and .build == strenv(TAG)) | .reason
  ' "$DENYLIST")"

  if [[ -n "$reason" ]]; then
    BLOCKED+=("$svc|$dev_tag|$reason")
    continue
  fi

  CHANGES+=("$svc|$prod_tag|$dev_tag")
done

if [[ ${#BLOCKED[@]} -gt 0 ]]; then
  echo "Denied builds, excluded from this release:" >&2
  for blocked in "${BLOCKED[@]}"; do
    IFS='|' read -r svc tag reason <<< "$blocked"
    printf '  %-12s %-10s %s\n' "$svc" "$tag" "$reason" >&2
  done
fi

# "Nothing changed" and "everything I would have shipped is poisoned" are
# different states and must never print the same message.
if [[ ${#CHANGES[@]} -eq 0 && ${#BLOCKED[@]} -gt 0 ]]; then
  echo "ERROR: every candidate build is denied. Nothing released." >&2
  exit 1
fi

if [[ ${#CHANGES[@]} -eq 0 ]]; then
  echo "Nothing to release: prod already matches dev."
  exit 0
fi

# Name the branch after the newest build in this release, so each release says
# what it contains: release/2026-W40-B3. Tags look like 26W40B3, so the build
# ordinal is whatever follows the B. The last |-field of a change is the dev
# tag whatever else the record carries. A tag that does not parse (a SHA, say)
# is ignored, and a release with no parsable tag falls back to release/2026-W40.
BUILD_N=0
for change in "${CHANGES[@]}"; do
  tag="${change##*|}"
  if [[ "$tag" =~ ^[0-9]{2}W[0-9]{2}B([0-9]+)$ ]]; then
    ordinal=$((10#${BASH_REMATCH[1]}))
    (( ordinal > BUILD_N )) && BUILD_N=$ordinal
  fi
done
BASE_BRANCH="release/${WEEK}"
(( BUILD_N > 0 )) && BASE_BRANCH+="-B${BUILD_N}"

# The branch from an earlier release still exists locally and on the remote.
# That is only a collision here if a re-release has the same newest build, which
# is unusual but possible, so fall back to a -2, -3 suffix. The remote check
# matters: a free local name that exists on origin would build the release
# commit and then fail at the push.
git fetch --quiet --prune origin
BRANCH="$BASE_BRANCH"
n=2
while git show-ref --verify --quiet "refs/heads/${BRANCH}" \
   || git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do
  BRANCH="${BASE_BRANCH}-${n}"
  n=$((n + 1))
done
# What the commit and PR are called, for example 2026-W40-B3.
RELEASE_ID="${BRANCH#release/}"

git switch -c "$BRANCH"

# Write the new tags. This is the entire mechanical content of a release.
BODY="## Release ${RELEASE_ID}"$'\n\n'"| Service | From | To |"$'\n'"|---|---|---|"$'\n'
for change in "${CHANGES[@]}"; do
  IFS='|' read -r svc from to <<< "$change"
  yq -i '(.images[] | select(.name == "'"$svc"'") | .newTag) = "'"$to"'"' \
    "kubernetes/overlays/local/prod/$svc/kustomization.yaml"
  BODY+="| \`$svc\` | \`${from:0:12}\` | \`${to:0:12}\` |"$'\n'
done

BODY+=$'\n'"Promote **service-2 before service-1**: service-1 calls service-2, so"
BODY+=" promoting the dependency first keeps each canary judgment about one change."

# Reviewers need to see what is NOT in the release as much as what is.
if [[ ${#BLOCKED[@]} -gt 0 ]]; then
  BODY+=$'\n\n'"### Excluded by the deny list"$'\n\n'"| Service | Build | Reason |"$'\n'"|---|---|---|"$'\n'
  for blocked in "${BLOCKED[@]}"; do
    IFS='|' read -r svc tag reason <<< "$blocked"
    BODY+="| \`$svc\` | \`$tag\` | $reason |"$'\n'
  done
fi

git add kubernetes/overlays/local/prod
git commit -m "release(prod): ${RELEASE_ID}"
git push -u origin "$BRANCH"

gh pr create --title "release(prod): ${RELEASE_ID}" --body "$BODY" --base main

git switch main
echo "PR opened. Review the diff: it is your release note."
