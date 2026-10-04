#!/usr/bin/env bash
# Shows which build each service is on, in Git and in the cluster.
#
# Usage: scripts/current-builds.sh <dev|prod>
#
# Two columns of truth, because they can differ and the difference is the point:
#   GIT      what the overlay on origin/main says the environment should run.
#   RUNNING  what the cluster is serving right now (the Rollout's stable ReplicaSet).
# During a canary there is a third: the new build being tried alongside stable.
# Read-only. It changes nothing.
set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "prod" ]]; then
  echo "ERROR: environment must be dev or prod." >&2
  echo "  Usage: gmake dev-current   or   gmake prod-current" >&2
  exit 1
fi

SERVICES=(service-1 service-2)
# One cluster for now. When the EKS cluster exists, this is where a second
# (context, tree) pair gets added.
TREE=local
CONTEXT="${CONTEXT:-k3d-platform}"
NAMESPACE="platform-${ENVIRONMENT}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Compare against what is on the remote, not whatever this checkout last pulled.
git fetch --quiet origin 2>/dev/null || echo "NOTE: could not fetch origin; GIT column may be stale." >&2

# Is the cluster reachable at all? Without it we can still show the Git column.
CLUSTER_UP=1
kubectl --context "$CONTEXT" get ns "$NAMESPACE" >/dev/null 2>&1 || CLUSTER_UP=0

git_tag() { # <service>
  git show "origin/main:kubernetes/overlays/${TREE}/${ENVIRONMENT}/$1/kustomization.yaml" 2>/dev/null \
    | SVC="$1" yq '.images[] | select(.name == strenv(SVC)) | .newTag' 2>/dev/null || true
}

# The image tag of the ReplicaSet with a given pod-template hash.
rs_tag() { # <service> <hash>
  [[ -n "$2" ]] || return 0
  local image
  image="$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get rs \
    -l "rollouts-pod-template-hash=$2" \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "${image##*:}"
}

echo
if [[ "$CLUSTER_UP" -eq 1 ]]; then
  echo "${ENVIRONMENT} builds   (cluster ${CONTEXT}, namespace ${NAMESPACE})"
else
  echo "${ENVIRONMENT} builds   (cluster ${CONTEXT} not reachable: showing Git only. Try: gmake resume)"
fi
echo
printf '  %-11s %-12s %-12s %-12s %s\n' SERVICE GIT RUNNING CANARY STATE

NOTES=()
for svc in "${SERVICES[@]}"; do
  git_t="$(git_tag "$svc")"
  git_t="${git_t:-?}"
  running="n/a"; canary="-"; state="n/a"

  if [[ "$CLUSTER_UP" -eq 1 ]]; then
    read -r stable current phase < <(kubectl --context "$CONTEXT" -n "$NAMESPACE" \
      get rollout "$svc" \
      -o jsonpath='{.status.stableRS} {.status.currentPodHash} {.status.phase}{"\n"}' 2>/dev/null || true) || true
    stable="${stable:-}"; current="${current:-}"; phase="${phase:-}"
    if [[ -n "$stable" ]]; then
      running="$(rs_tag "$svc" "$stable")"
      running="${running:-?}"
    fi
    # A different current hash than stable means a new version is mid-rollout.
    if [[ -n "$current" && "$current" != "$stable" ]]; then
      canary="$(rs_tag "$svc" "$current")"
      canary="${canary:-?}"
    fi
    state="${phase:-unknown}"
  fi

  printf '  %-11s %-12s %-12s %-12s %s\n' "$svc" "$git_t" "$running" "$canary" "$state"

  if [[ "$CLUSTER_UP" -eq 1 ]]; then
    if [[ "$canary" != "-" && "$state" == "Paused" ]]; then
      NOTES+=("$svc: canary $canary is paused, waiting for you. gmake canary-promote SVC=$svc  or  gmake canary-abort SVC=$svc")
    elif [[ "$canary" != "-" ]]; then
      NOTES+=("$svc: rolling out $canary beside stable $running. Watch: gmake canary-status SVC=$svc")
    elif [[ "$running" != "$git_t" && "$running" != "n/a" && "$git_t" != "?" ]]; then
      NOTES+=("$svc: Git says $git_t but $running is running. ArgoCD has not caught up yet (it polls every 3 minutes).")
    fi
  fi
done

if [[ ${#NOTES[@]} -gt 0 ]]; then
  echo
  for note in "${NOTES[@]}"; do echo "  * $note"; done
fi
echo
