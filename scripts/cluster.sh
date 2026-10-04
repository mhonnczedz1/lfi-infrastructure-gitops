#!/usr/bin/env bash
# Brings a cluster up, removes its platform, or destroys it.
#
# Usage: scripts/cluster.sh <up|down|destroy>
#   Asks which cluster: local (k3d-platform), eks (lfi-eks), or both. Name it up
#   front and nothing is asked:  gmake up CLUSTER=eks
#
# The work itself lives in the Makefile's internal _local-* and _eks-* targets,
# which hold the Terraform and the .env bridge. This script only chooses which
# of them to run, in a safe order, and says what to do next.
#
#   up       builds the cluster, then installs ArgoCD, which syncs the apps.
#   down     removes what Terraform put inside the cluster. The cluster stays.
#   destroy  removes everything, including the database. Asks you to type it.
set -euo pipefail

ACTION="${1:-}"
case "$ACTION" in
  up|down|destroy) ;;
  *) echo "ERROR: action must be up, down or destroy (got '${ACTION}')." >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"
MAKE_CMD="${MAKE:-gmake}"

case "$ACTION" in
  up)      pick_cluster "bring up" yes ;;
  down)    pick_cluster "remove the platform from" yes "running" ;;
  destroy) pick_cluster "destroy" yes "running" ;;
esac

# Order matters when both are chosen. Bring local up first, since it is quick
# and free. Tear EKS down first, since it is the one that bills.
ORDER=("${PICKED_CLUSTERS[@]}")
if [[ "$ACTION" != "up" && ${#ORDER[@]} -eq 2 ]]; then ORDER=(eks local); fi

has() { local c; for c in "${ORDER[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }

# Say what is about to happen in terms of time and money, before it does.
echo
echo "About to ${ACTION}: ${ORDER[*]}"
if [[ "$ACTION" == "up" ]]; then
  has local && echo "  local: builds the k3d cluster and installs ArgoCD. A few minutes."
  if has eks; then
    echo "  eks:   builds the VPC, cluster, node and load balancer, then installs ArgoCD."
    echo "         Takes 15 to 25 minutes. BILLING STARTS: about 0.23 USD an hour until you destroy it."
    # EKS needs working AWS credentials. Check now, not 10 minutes in.
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
      echo >&2
      echo "ERROR: AWS credentials are not working, so the EKS cluster cannot be built." >&2
      echo "  Set a profile:   export AWS_PROFILE=<your profile>" >&2
      echo "  Log in (if SSO): aws sso login --profile \"\$AWS_PROFILE\"" >&2
      exit 1
    fi
  fi
fi
if [[ "$ACTION" == "down" ]]; then
  echo "  Removes ArgoCD, the namespaces and the Postgres secrets. The cluster keeps running."
  echo "  Bring the platform back later with: gmake up"
fi
if [[ "$ACTION" == "destroy" ]]; then
  echo "  Deletes the cluster and everything in it, INCLUDING EVERY ROW IN THE DATABASE."
  has eks && echo "  eks is destroyed first, since it is the one that bills."
fi

if [[ "$ACTION" == "destroy" && "${ASSUME_YES:-}" != "1" ]]; then
  echo
  read -r -p "Type 'destroy' to continue: " typed
  [[ "$typed" == "destroy" ]] || cancel
elif [[ "$ACTION" == "down" || ( "$ACTION" == "up" && "${ORDER[*]}" == *eks* ) ]]; then
  echo
  confirm "Continue?"
fi

show_equivalent "gmake ${ACTION}"

DONE=()
for c in "${ORDER[@]}"; do
  echo
  echo "=== ${ACTION}: ${c} ==="
  if ! "$MAKE_CMD" --no-print-directory "_${c}-${ACTION}"; then
    echo >&2
    echo "ERROR: '${ACTION}' failed on ${c}." >&2
    [[ ${#DONE[@]} -gt 0 ]] && echo "  Already finished: ${DONE[*]}" >&2
    echo "  The output above has the cause. Fix it and rerun: gmake ${ACTION} CLUSTER=${c}" >&2
    exit 1
  fi
  DONE+=("$c")
done

case "$ACTION" in
  up)
    STEPS=("gmake status           see what is running. ArgoCD takes up to 3 minutes to sync the apps.")
    has eks && STEPS+=("gmake destroy          when you are done with EKS. It bills while it exists.")
    next_steps "${STEPS[@]}"
    ;;
  down)
    next_steps "gmake up               put the platform back" \
               "gmake destroy          remove the cluster too"
    ;;
  destroy)
    next_steps "gmake up               rebuild from scratch"
    has eks && echo && echo "Check nothing is still billing: the AWS console, or the commands in the EKS teardown task of the guide."
    ;;
esac
