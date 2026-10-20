#!/usr/bin/env bash
# Shows which build each service is on, in Git and in the cluster, and where to
# reach it.
#
# Usage: scripts/status.sh
#   Asks which cluster (local, eks, both) and which environment (dev, prod,
#   both). Name them up front and nothing is asked:
#     gmake status CLUSTER=eks ENVIRONMENT=prod
#
# Two columns of truth, because they can differ and the difference is the point:
#   GIT      what the overlay on origin/main says the environment should run.
#   RUNNING  what the cluster is serving right now (the Rollout's stable ReplicaSet).
# During a canary there is a third: the new build being tried beside stable.
# Read-only. It changes nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

pick_cluster "look at" yes "running"
pick_stage "look at" yes
show_equivalent "gmake status"

# Compare against what is on the remote, not whatever this checkout last pulled.
git fetch --quiet origin 2>/dev/null || echo "NOTE: could not fetch origin; the GIT column may be stale." >&2

git_tag() { # <cluster> <stage> <service>
  git show "origin/main:kubernetes/overlays/$1/$2/$3/kustomization.yaml" 2>/dev/null \
    | SVC="$3" yq '.images[] | select(.name == strenv(SVC)) | .newTag' 2>/dev/null || true
}

rs_tag() { # <context> <namespace> <hash>
  [[ -n "$3" ]] || return 0
  local image
  image="$(kubectl --context "$1" -n "$2" get rs -l "rollouts-pod-template-hash=$3" \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "${image##*:}"
}

PAUSED=()        # "cluster/service" with a canary waiting for a decision
ROLLING=()       # canary moving on its own
DOWN=()          # clusters that could not be reached
BEHIND=()        # Git and the cluster disagree with no canary explaining it
DEV_AHEAD=0      # dev and prod differ in Git, so there is something to release

for cluster in "${PICKED_CLUSTERS[@]}"; do
  ctx="$(cluster_context "$cluster")"
  up=1
  kubectl --context "$ctx" --request-timeout=4s get ns argocd >/dev/null 2>&1 || up=0
  [[ "$up" -eq 0 ]] && DOWN+=("$cluster")

  for stage in "${PICKED_STAGES[@]}"; do
    ns="platform-${stage}"
    echo
    if [[ "$up" -eq 1 ]]; then
      echo "${cluster} ${stage}   (cluster ${ctx}, namespace ${ns})"
    else
      echo "${cluster} ${stage}   (cluster ${ctx} not reachable: showing Git only)"
    fi
    printf '  %-11s %-12s %-12s %-12s %s\n' SERVICE GIT RUNNING CANARY STATE

    for svc in "${LFI_SERVICES[@]}"; do
      git_t="$(git_tag "$cluster" "$stage" "$svc")"; git_t="${git_t:-?}"
      running="n/a"; canary="-"; state="n/a"

      if [[ "$up" -eq 1 ]]; then
        stable=""; current=""; phase=""
        read -r stable current phase < <(kubectl --context "$ctx" -n "$ns" get rollout "$svc" \
          -o jsonpath='{.status.stableRS} {.status.currentPodHash} {.status.phase}{"\n"}' 2>/dev/null || true) || true
        if [[ -n "$stable" ]]; then running="$(rs_tag "$ctx" "$ns" "$stable")"; running="${running:-?}"; fi
        if [[ -n "$current" && "$current" != "$stable" ]]; then
          canary="$(rs_tag "$ctx" "$ns" "$current")"; canary="${canary:-?}"
        fi
        state="${phase:-unknown}"

        if [[ "$canary" != "-" && "$state" == "Paused" ]]; then
          PAUSED+=("${cluster}/${svc}")
        elif [[ "$canary" != "-" ]]; then
          ROLLING+=("${cluster}/${svc}")
        elif [[ "$running" != "$git_t" && "$running" != "n/a" && "$git_t" != "?" ]]; then
          BEHIND+=("${cluster}/${svc}: Git says ${git_t}, running ${running}")
        fi
      fi
      printf '  %-11s %-12s %-12s %-12s %s\n' "$svc" "$git_t" "$running" "$canary" "$state"

      # Is there something in dev that prod has not had yet?
      if [[ "$stage" == "prod" ]]; then
        dev_t="$(git_tag "$cluster" dev "$svc")"
        [[ -n "$dev_t" && "$git_t" != "?" && "$dev_t" != "$git_t" ]] && DEV_AHEAD=1
      fi
    done
  done

  # Where to reach it. Printed once per cluster.
  echo
  echo "  ${cluster} addresses:"
  if [[ "$cluster" == "local" ]]; then
    echo "    dev     http://dev.localhost:8080"
    echo "    prod    http://prod.localhost:8080"
    echo "    argocd  http://argocd.localhost:8080"
  else
    lb=""
    [[ "$up" -eq 1 ]] && lb="$(kubectl --context "$ctx" -n traefik get svc traefik \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "$lb" ]]; then
      echo "    dev     curl -H 'Host: dev.eks.test'  http://${lb}/"
      echo "    prod    curl -H 'Host: prod.eks.test' http://${lb}/"
      echo "    argocd  kubectl --context ${ctx} -n argocd port-forward svc/argocd-server 8081:80"
    else
      echo "    (no load balancer address yet)"
    fi
  fi
done

# What to do about what was just seen. Each line is a command, in order of urgency.
STEPS=()
if [[ ${#PAUSED[@]} -gt 0 ]]; then
  STEPS+=("gmake canary          ${PAUSED[*]}: a canary is paused, waiting for you. Promote service-2 first.")
fi
if [[ ${#ROLLING[@]} -gt 0 ]]; then
  STEPS+=("gmake canary          ${ROLLING[*]}: a rollout is in progress. Choose 'watch' to follow it.")
fi
if [[ ${#BEHIND[@]} -gt 0 ]]; then
  STEPS+=("wait or refresh       ${BEHIND[0]}. ArgoCD polls Git every 3 minutes.")
fi
if [[ ${#DOWN[@]} -gt 0 ]]; then
  for c in "${DOWN[@]}"; do
    if [[ "$c" == "local" ]]; then
      STEPS+=("gmake resume          local is not reachable. Resume it if it was paused, or: gmake up CLUSTER=local")
    else
      STEPS+=("gmake up              eks is not reachable: gmake up CLUSTER=eks")
    fi
  done
fi
if [[ "$DEV_AHEAD" -eq 1 ]]; then
  STEPS+=("gmake release         dev is ahead of prod in Git. Open a release PR to promote it.")
fi
if [[ ${#STEPS[@]} -eq 0 ]]; then
  STEPS+=("gmake release         promote dev to prod when you are ready" \
          "gmake rollback        go back to an earlier build if something is wrong")
fi
next_steps "${STEPS[@]}"
echo
