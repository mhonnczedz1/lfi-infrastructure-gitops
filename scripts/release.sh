#!/usr/bin/env bash
# Opens the weekly prod release PRs, one in each service's config repository.
#
# Usage: scripts/release.sh
#   Asks which cluster (local, eks, or both) and which service (or both). Name
#   them up front and nothing is asked:
#     gmake release CLUSTER=eks SVC=service-1
#   DRY_RUN=1 shows what would be released and stops, touching nothing.
#   Clusters are allowed to drift apart: releasing to one leaves the other where
#   it was, until you release to it.
#
# Reads the image tag the "from" environment (dev, unless the service's
# subscription says otherwise) is running and writes it into the "to"
# environment (prod). Nothing is built: the images already exist in GHCR and
# have been serving dev traffic all week. This script only moves a reference.
#
# Each service's manifests live in that service's own config repository, which
# the team owns. So a release is one PR per service, opened in that repository,
# and that team's review rules (its CODEOWNERS) are what gate prod. The deny
# list stays here, in the GitOps repository: it is the platform's veto.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

pick_cluster "release to" yes
pick_service "release" yes
TREES=("${PICKED_CLUSTERS[@]}")
SERVICES=("${PICKED_SERVICES[@]}")
show_equivalent "gmake release"

SCOPE="${TREES[*]} / ${SERVICES[*]}"
PARTIAL=0
[[ ${#TREES[@]} -lt ${#LFI_CLUSTERS[@]} || ${#SERVICES[@]} -lt ${#LFI_SERVICES[@]} ]] && PARTIAL=1
# %G is the ISO week-numbering year, not the calendar year. They diverge at
# New Year: 2027-01-01 falls in ISO week 53 of 2026, so %Y-W%V would name that
# release 2027-W53, a week that does not exist. UTC to match CI.
WEEK="$(date -u +%G-W%V)"

DENYLIST="releases/denied-builds.yaml"
if [[ ! -f "$DENYLIST" ]]; then
  echo "ERROR: ${DENYLIST} is missing. Refusing to release without it." >&2
  exit 1
fi

# Every config repo that takes part must be a clean checkout on an up-to-date
# main, for the reason a release commit must never carry an unrelated change.
for svc in "${SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  [[ -d "$cfg/.git" ]] || { echo "ERROR: $svc's config repo is not checked out at $cfg." >&2; exit 1; }
  if [[ -n "$(git -C "$cfg" status --porcelain)" ]]; then
    echo "ERROR: $cfg has uncommitted changes. Commit or stash first." >&2
    exit 1
  fi
  git -C "$cfg" switch main >/dev/null 2>&1
  git -C "$cfg" pull --ff-only --quiet
done

tag_in() { # <file> <service>
  SVC="$2" yq '.images[] | select(.name == strenv(SVC)) | .newTag' "$1"
}

# Collect what would change, before changing anything, so the script can decide
# whether there is a release to make and can build the PR bodies.
declare -a CHANGES=()    # svc|cluster|from|to
declare -a BLOCKED=()    # svc|cluster|tag|reason
for svc in "${SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  from_env="$(promote_from "$svc")"; to_env="$(promote_to "$svc")"
  for tree in "${TREES[@]}"; do
    src="$cfg/$tree/$from_env/app/kustomization.yaml"
    dst="$cfg/$tree/$to_env/app/kustomization.yaml"
    if [[ ! -f "$src" || ! -f "$dst" ]]; then
      echo "NOTE: $svc has no $from_env and $to_env on $tree. Skipped." >&2
      continue
    fi
    dev_tag="$(tag_in "$src" "$svc")"
    prod_tag="$(tag_in "$dst" "$svc")"
    [[ "$dev_tag" == "$prod_tag" ]] && continue

    # A denied build drops out of the release. It is never silently replaced
    # with an older one: shipping something other than what you asked for is
    # exactly the surprise this whole process exists to prevent. strenv reads
    # the values as strings so a numeric-looking tag is not coerced.
    reason="$(SVC="$svc" TAG="$dev_tag" yq '
      .denied[] | select(.service == strenv(SVC) and .build == strenv(TAG)) | .reason
    ' "$DENYLIST")"

    if [[ -n "$reason" ]]; then
      BLOCKED+=("$svc|$tree|$dev_tag|$reason")
      continue
    fi
    CHANGES+=("$svc|$tree|$prod_tag|$dev_tag")
  done
done

if [[ ${#BLOCKED[@]} -gt 0 ]]; then
  echo "Denied builds, excluded from this release:" >&2
  for blocked in "${BLOCKED[@]}"; do
    IFS='|' read -r svc tree tag reason <<< "$blocked"
    printf '  %-18s %-10s %s\n' "$tree/$svc" "$tag" "$reason" >&2
  done
fi

# "Nothing changed" and "everything I would have shipped is poisoned" are
# different states and must never print the same message.
if [[ ${#CHANGES[@]} -eq 0 && ${#BLOCKED[@]} -gt 0 ]]; then
  echo "ERROR: every candidate build is denied. Nothing released." >&2
  exit 1
fi

if [[ ${#CHANGES[@]} -eq 0 ]]; then
  echo "Nothing to release: prod already matches dev for ${SCOPE}."
  next_steps "gmake status           compare dev and prod on every cluster" \
             "gmake release          choose a different cluster or service"
  exit 0
fi

# DRY_RUN=1 shows what would be released and stops, touching nothing.
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "Would release (dry run, nothing changed):"
  for change in "${CHANGES[@]}"; do
    IFS='|' read -r svc tree from to <<< "$change"
    printf '  %-10s %-6s %s -> %s\n' "$svc" "$tree" "$from" "$to"
  done
  exit 0
fi

# One pass per service that has something to ship.
PRS=()
for svc in "${SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  from_env="$(promote_from "$svc")"; to_env="$(promote_to "$svc")"

  # This service's changes only.
  MINE=()
  for change in "${CHANGES[@]}"; do
    [[ "${change%%|*}" == "$svc" ]] && MINE+=("$change")
  done
  [[ ${#MINE[@]} -gt 0 ]] || continue

  # Name the branch after the newest build in this release, so each release says
  # what it contains: release/2026-W40-B3. Tags look like 26W40B3, so the build
  # ordinal is whatever follows the B. A tag that does not parse (a SHA, say) is
  # ignored, and a release with no parsable tag falls back to release/2026-W40.
  BUILD_N=0
  for change in "${MINE[@]}"; do
    tag="${change##*|}"
    if [[ "$tag" =~ ^[0-9]{2}W[0-9]{2}B([0-9]+)$ ]]; then
      ordinal=$((10#${BASH_REMATCH[1]}))
      (( ordinal > BUILD_N )) && BUILD_N=$ordinal
    fi
  done
  BASE_BRANCH="release/${WEEK}"
  (( BUILD_N > 0 )) && BASE_BRANCH+="-B${BUILD_N}"

  # The branch from an earlier release still exists locally and on the remote.
  # Fall back to a -2, -3 suffix. The remote check matters: a free local name
  # that exists on origin would build the release commit and fail at the push.
  git -C "$cfg" fetch --quiet --prune origin
  BRANCH="$BASE_BRANCH"
  n=2
  while git -C "$cfg" show-ref --verify --quiet "refs/heads/${BRANCH}" \
     || git -C "$cfg" show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do
    BRANCH="${BASE_BRANCH}-${n}"
    n=$((n + 1))
  done
  RELEASE_ID="${BRANCH#release/}"
  TITLE="release(${to_env}): ${RELEASE_ID}"
  [[ "$PARTIAL" -eq 1 ]] && TITLE+=" [${SCOPE}]"

  git -C "$cfg" switch -c "$BRANCH" >/dev/null

  # Write the new tags. This is the entire mechanical content of a release.
  BODY="## Release ${RELEASE_ID}: ${svc}"$'\n\n'"Scope: ${SCOPE}"$'\n\n'"| Cluster | From | To |"$'\n'"|---|---|---|"$'\n'
  for change in "${MINE[@]}"; do
    IFS='|' read -r _ tree from to <<< "$change"
    file="$cfg/$tree/$to_env/app/kustomization.yaml"
    yq -i '(.images[] | select(.name == "'"$svc"'") | .newTag) = "'"$to"'"' "$file"
    git -C "$cfg" add "$tree/$to_env/app/kustomization.yaml"
    BODY+="| \`$tree\` | \`${from:0:12}\` | \`${to:0:12}\` |"$'\n'
  done

  # Dependencies go first, so each canary judgment is about one change.
  for dep in $(service_deps "$svc"); do
    if [[ " ${SERVICES[*]} " == *" $dep "* ]]; then
      BODY+=$'\n'"Promote **${dep} before ${svc}**: ${svc} calls ${dep}, so promoting the dependency"
      BODY+=" first keeps each canary judgment about one change."
    fi
  done

  # Reviewers need to see what is NOT in the release as much as what is.
  MY_BLOCKED=()
  for blocked in ${BLOCKED[@]+"${BLOCKED[@]}"}; do
    [[ "${blocked%%|*}" == "$svc" ]] && MY_BLOCKED+=("$blocked")
  done
  if [[ ${#MY_BLOCKED[@]} -gt 0 ]]; then
    BODY+=$'\n\n'"### Excluded by the deny list"$'\n\n'"| Cluster | Build | Reason |"$'\n'"|---|---|---|"$'\n'
    for blocked in "${MY_BLOCKED[@]}"; do
      IFS='|' read -r _ tree tag reason <<< "$blocked"
      BODY+="| \`$tree\` | \`$tag\` | $reason |"$'\n'
    done
  fi

  git -C "$cfg" commit -q -m "$TITLE"
  git -C "$cfg" push -q -u origin "$BRANCH"
  url="$(cd "$cfg" && gh pr create --title "$TITLE" --body "$BODY" --base main)"
  git -C "$cfg" switch main >/dev/null 2>&1
  PRS+=("$svc  $url")
done

echo "PRs opened. Review each diff: it is your release note."
for pr in "${PRS[@]}"; do echo "  $pr"; done
next_steps "merge the PRs          ArgoCD then starts a canary that pauses at 50 percent." \
           "gmake status           watch the new build arrive" \
           "gmake canary           promote it. Dependencies first, as the PR says." \
           "gmake rollback         go back to the last good build if it misbehaves"
