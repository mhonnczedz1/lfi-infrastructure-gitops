#!/usr/bin/env bash
# Operates on an in-flight prod canary: watch it, promote it, or abort it.
#
# Usage: scripts/canary.sh [<status|promote|abort>] [<service>]
#   Asks what you want to do, on which cluster, and for which service, showing
#   each rollout's state before you choose. promote and abort then confirm.
#   Name things up front and nothing is asked:
#     gmake canary ACTION=promote CLUSTER=eks SVC=service-2
#   Without a terminal, a missing answer is an error with a hint, never a prompt.
#
# These change no desired state, which is why they are commands rather than
# commits. They advance or unwind a convergence toward what Git already says.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

ACTION="${1:-${ACTION:-}}"
SVC="${2:-${SVC:-}}"
NAMESPACE="${NAMESPACE:-platform-prod}"
PICKED_BY_MENU=0

# --- 1. What do you want to do? ---------------------------------------------
if [[ -z "$ACTION" ]]; then
  is_tty || usage_error "ACTION is required (watch, promote or abort)." \
    "gmake canary ACTION=promote CLUSTER=local SVC=service-2"
  echo
  echo "What do you want to do with a prod canary?"
  echo "  1) watch     follow a rollout live. Changes nothing."
  echo "  2) promote   finish a paused rollout: the new build takes all the traffic."
  echo "  3) abort     stop the canary. Stable keeps serving, and Git still points at the new build."
  ask "Choose a number or name"
  case "$REPLY_VALUE" in
    1|watch|status) ACTION=status ;;
    2|promote)      ACTION=promote ;;
    3|abort)        ACTION=abort ;;
    *) usage_error "'${REPLY_VALUE}' is not watch, promote or abort." ;;
  esac
  EQUIV+=" ACTION=${ACTION}"
  PICKED_BY_MENU=1
fi
[[ "$ACTION" == "watch" ]] && ACTION=status
case "$ACTION" in
  status|promote|abort) ;;
  *) usage_error "ACTION must be watch, promote or abort (got '${ACTION}')." ;;
esac

# --- 2. Which cluster? One at a time: two canaries are two separate judgments. ---
VERB="$ACTION"; [[ "$ACTION" == "status" ]] && VERB="watch"
pick_cluster "$VERB a canary on" no "running"
CLUSTER_NAME="${PICKED_CLUSTERS[0]}"
CONTEXT="$(cluster_context "$CLUSTER_NAME")"
[[ -z "${CLUSTER:-}" ]] && PICKED_BY_MENU=1

# What each Rollout is doing on this cluster.
rollout_fields() { # <service> -> "<stableRS> <currentPodHash> <phase>"
  kubectl --context "$CONTEXT" -n "$NAMESPACE" get rollout "$1" \
    -o jsonpath='{.status.stableRS} {.status.currentPodHash} {.status.phase}{"\n"}' 2>/dev/null || true
}
rs_tag() { # <hash>
  [[ -n "$1" ]] || return 0
  local image
  image="$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get rs -l "rollouts-pod-template-hash=$1" \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "${image##*:}"
}

# Sets DESC, and adds to IN_FLIGHT. Runs in the main shell on purpose: a command
# substitution is a subshell and would lose the IN_FLIGHT update.
declare -a IN_FLIGHT=()
DESC=""
describe() { # <service>
  local stable current phase running canary
  read -r stable current phase <<< "$(rollout_fields "$1")" || true
  stable="${stable:-}"; current="${current:-}"; phase="${phase:-}"
  if [[ -z "$phase" ]]; then DESC="state unknown (cluster not reachable?)"; return; fi
  running="$(rs_tag "$stable")"
  if [[ -n "$current" && "$current" != "$stable" ]]; then
    canary="$(rs_tag "$current")"
    IN_FLIGHT+=("$1")
    DESC="${phase}: stable ${running:-?}, new ${canary:-?} rolling out"
  else
    DESC="${phase}: on ${running:-?}, nothing rolling out"
  fi
}

# --- 3. Which service? Show what each one is doing first. ---------------------
if [[ -z "$SVC" ]]; then
  is_tty || usage_error "SVC is required (service-1 or service-2)." \
    "gmake canary ACTION=${ACTION} CLUSTER=${CLUSTER_NAME} SVC=service-2"
  echo
  echo "Which service on ${CLUSTER_NAME}?"
  i=1
  for s in "${LFI_SERVICES[@]}"; do
    describe "$s"
    printf '  %d) %-10s %s\n' "$i" "$s" "$DESC"
    i=$((i + 1))
  done

  DEFAULT=""
  if [[ ${#IN_FLIGHT[@]} -eq 1 ]]; then
    DEFAULT="${IN_FLIGHT[0]}"
  elif [[ ${#IN_FLIGHT[@]} -gt 1 && "$ACTION" == "promote" ]]; then
    DEFAULT="service-2"
    echo
    echo "  Both are rolling out. service-2 goes first: service-1 calls it."
  fi
  if [[ ${#IN_FLIGHT[@]} -eq 0 && "$ACTION" != "status" ]]; then
    echo
    echo "  Nothing is rolling out right now, so there is nothing to ${ACTION}."
    echo "  Merge a release PR first (gmake release), or check: gmake status"
  fi
  echo
  ask "Choose a number or name" "$DEFAULT"
  if [[ "$REPLY_VALUE" =~ ^[0-9]+$ && "$REPLY_VALUE" -ge 1 && "$REPLY_VALUE" -le ${#LFI_SERVICES[@]} ]]; then
    SVC="${LFI_SERVICES[$((REPLY_VALUE - 1))]}"
  else
    SVC="$REPLY_VALUE"
  fi
  EQUIV+=" SVC=${SVC}"
  PICKED_BY_MENU=1
fi

[[ " ${LFI_SERVICES[*]} " == *" $SVC "* ]] || usage_error "SVC must be service-1 or service-2 (got '${SVC}')."

# --- 4. Confirm, when a menu chose for you and the action changes traffic. ----
if [[ "$PICKED_BY_MENU" -eq 1 && "$ACTION" != "status" && "${ASSUME_YES:-}" != "1" ]]; then
  echo
  IN_FLIGHT=(); describe "$SVC"
  echo "  ${CLUSTER_NAME}/${SVC}: ${DESC}"
  case "$ACTION" in
    promote) echo "  Promoting finishes the rollout: the new build takes all the traffic." ;;
    abort)   echo "  Aborting scales the canary to zero. Stable keeps serving, and Git still points at the new build." ;;
  esac
  confirm "Go ahead and ${ACTION} ${SVC} on ${CLUSTER_NAME}?"
fi

show_equivalent "gmake canary"

# --- 5. Do it, then point at what comes next. -------------------------------
case "$ACTION" in
  status)
    echo
    echo "Watching ${CLUSTER_NAME}/${SVC}. Ctrl-C stops watching and does not affect the rollout."
    echo "When it shows Paused:  gmake canary ACTION=promote CLUSTER=${CLUSTER_NAME} SVC=${SVC}"
    echo "                       gmake canary ACTION=abort   CLUSTER=${CLUSTER_NAME} SVC=${SVC}"
    exec kubectl argo rollouts get rollout "$SVC" -n "$NAMESPACE" --context "$CONTEXT" --watch
    ;;
  promote)
    kubectl argo rollouts promote "$SVC" -n "$NAMESPACE" --context "$CONTEXT"
    STEPS=("gmake canary          choose 'watch' to follow it finish" "gmake status          check every build at once")
    [[ "$SVC" == "service-2" ]] && STEPS=("gmake canary          now promote service-1 if it is in this release" "${STEPS[@]}")
    next_steps "${STEPS[@]}"
    ;;
  abort)
    kubectl argo rollouts abort "$SVC" -n "$NAMESPACE" --context "$CONTEXT"
    echo
    echo "Canary removed from service. Stable is unaffected."
    echo "This does NOT undo the release: Git still points prod at the bad tag,"
    echo "so the next sync will try again. Make it stick by going back:"
    next_steps "gmake rollback         open a PR that sets ${SVC} back to the last good build" \
               "gmake status           confirm what is running"
    ;;
esac
