#!/usr/bin/env bash
# Operates on an in-flight prod canary: watch it, promote it, or abort it.
#
# Usage: scripts/canary.sh [<status|promote|abort>] [<service>]
#   Asks what you want to do, on which cluster, and for which service, showing
#   each rollout's state before you choose. promote and abort then confirm.
#   Name things up front and nothing is asked:
#     gmake canary ACTION=promote CLUSTER=eks SVC=team-2-service-2
#   Without a terminal, a missing answer is an error with a hint, never a prompt.
#
# These change no desired state, which is why they are commands rather than
# commits. They advance or unwind a convergence toward what Git already says.
#
# "Prod" is each service's promotion target (promotion.to in its subscription).
# The namespace and the Rollout's name are read from the Application ArgoCD made
# for it, because both are the team's choice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

ACTION="${1:-${ACTION:-}}"
SVC="${2:-${SVC:-}}"
PICKED_BY_MENU=0
EXAMPLE_SVC="$(first_to_promote ${LFI_RELEASABLE[@]+"${LFI_RELEASABLE[@]}"} 2>/dev/null || true)"

# --- 1. What do you want to do? ---------------------------------------------
if [[ -z "$ACTION" ]]; then
  is_tty || usage_error "ACTION is required (watch, promote or abort)." \
    "gmake canary ACTION=promote CLUSTER=local SVC=${EXAMPLE_SVC}"
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

# The namespace and Rollout of a service's prod environment on this cluster.
# Sets NS and RO; both empty if ArgoCD has no such Application.
locate() { # <service>
  NS=""; RO=""
  read -r NS RO <<< "$(app_rollout "$CONTEXT" "$(app_name "$(promote_to "$1")" "$1")")" || true
  NS="${NS:-}"; RO="${RO:-}"
}

# What each Rollout is doing on this cluster.
rollout_fields() { # <service> -> "<stableRS> <currentPodHash> <phase>"
  locate "$1"
  [[ -n "$RO" ]] || return 0
  kubectl --context "$CONTEXT" -n "$NS" get rollout "$RO" \
    -o jsonpath='{.status.stableRS} {.status.currentPodHash} {.status.phase}{"\n"}' 2>/dev/null || true
}
rs_tag() { # <hash>
  [[ -n "$1" ]] || return 0
  local image
  image="$(kubectl --context "$CONTEXT" -n "$NS" get rs -l "rollouts-pod-template-hash=$1" \
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
  locate "$1"
  stable="${stable:-}"; current="${current:-}"; phase="${phase:-}"
  if [[ -z "$phase" ]]; then DESC="state unknown (not on this cluster, or cluster not reachable?)"; return; fi
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
  is_tty || usage_error "SVC is required (one of: ${LFI_RELEASABLE[*]})." \
    "gmake canary ACTION=${ACTION} CLUSTER=${CLUSTER_NAME} SVC=${EXAMPLE_SVC}"
  echo
  echo "Which service on ${CLUSTER_NAME}?"
  i=1
  for s in "${LFI_RELEASABLE[@]}"; do
    describe "$s"
    printf '  %d) %-24s %s\n' "$i" "$s" "$DESC"
    i=$((i + 1))
  done

  DEFAULT=""
  if [[ ${#IN_FLIGHT[@]} -eq 1 ]]; then
    DEFAULT="${IN_FLIGHT[0]}"
  elif [[ ${#IN_FLIGHT[@]} -gt 1 && "$ACTION" == "promote" ]]; then
    DEFAULT="$(first_to_promote "${IN_FLIGHT[@]}")"
    echo
    echo "  Several are rolling out. ${DEFAULT} goes first$(called_by_note "$DEFAULT")."
  fi
  if [[ ${#IN_FLIGHT[@]} -eq 0 && "$ACTION" != "status" ]]; then
    echo
    echo "  Nothing is rolling out right now, so there is nothing to ${ACTION}."
    echo "  Merge a release PR first (gmake release), or check: gmake status"
  fi
  echo
  ask "Choose a number or name" "$DEFAULT"
  if [[ "$REPLY_VALUE" =~ ^[0-9]+$ && "$REPLY_VALUE" -ge 1 && "$REPLY_VALUE" -le ${#LFI_RELEASABLE[@]} ]]; then
    SVC="${LFI_RELEASABLE[$((REPLY_VALUE - 1))]}"
  else
    SVC="$REPLY_VALUE"
  fi
  EQUIV+=" SVC=${SVC}"
  PICKED_BY_MENU=1
fi

[[ " ${LFI_RELEASABLE[*]-} " == *" $SVC "* ]] || usage_error "SVC must be one of: ${LFI_RELEASABLE[*]-} (got '${SVC}')."
locate "$SVC"
[[ -n "$RO" ]] || usage_error "No Rollout found for $(app_name "$(promote_to "$SVC")" "$SVC") on ${CLUSTER_NAME}. Is it subscribed there, and is the cluster up?"

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
    echo "Watching ${CLUSTER_NAME}/${SVC} (Rollout ${RO} in ${NS}). Ctrl-C stops watching and does not affect the rollout."
    echo "When it shows Paused:  gmake canary ACTION=promote CLUSTER=${CLUSTER_NAME} SVC=${SVC}"
    echo "                       gmake canary ACTION=abort   CLUSTER=${CLUSTER_NAME} SVC=${SVC}"
    exec kubectl argo rollouts get rollout "$RO" -n "$NS" --context "$CONTEXT" --watch
    ;;
  promote)
    kubectl argo rollouts promote "$RO" -n "$NS" --context "$CONTEXT"
    STEPS=("gmake canary          choose 'watch' to follow it finish" "gmake status          check every build at once")
    DEPENDENTS="$(service_dependents "$SVC" | tr '\n' ' ')"
    [[ -n "$DEPENDENTS" ]] && STEPS=("gmake canary          now promote ${DEPENDENTS}if it is in this release" "${STEPS[@]}")
    next_steps "${STEPS[@]}"
    ;;
  abort)
    kubectl argo rollouts abort "$RO" -n "$NS" --context "$CONTEXT"
    echo
    echo "Canary removed from service. Stable is unaffected."
    echo "This does NOT undo the release: Git still points prod at the bad tag,"
    echo "so the next sync will try again. Make it stick by going back:"
    next_steps "gmake rollback         open a PR that sets ${SVC} back to the last good build" \
               "gmake status           confirm what is running"
    ;;
esac
