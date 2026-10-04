#!/usr/bin/env bash
# Operates on an in-flight prod canary: watch it, promote it, or abort it.
#
# Usage: scripts/canary.sh <status|promote|abort> [<service>]
#   With no service, in a terminal, it shows each service's rollout state and
#   asks which one. promote and abort then ask you to confirm. Name the service
#   (SVC=service-1 in the Makefile) and it does the action straight away, as the
#   canary commands always did. Without a terminal, a missing service is an
#   error with a hint, never a prompt.
#
# These change no desired state, which is why they are commands rather than
# commits. They advance or unwind a convergence toward what Git already says.
set -euo pipefail

ACTION="${1:-}"
SVC="${2:-}"
SERVICES=(service-1 service-2)
CONTEXT="${CONTEXT:-k3d-platform}"
NAMESPACE="${NAMESPACE:-platform-prod}"

case "$ACTION" in
  status|promote|abort) ;;
  *) echo "ERROR: action must be status, promote or abort (got '${ACTION}')." >&2; exit 1 ;;
esac

# What each Rollout is doing. Empty fields if the cluster cannot be reached.
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

# One line per service for the menu. Also fills IN_FLIGHT with the services that
# have a new version rolling out, which decides the default choice.
declare -a IN_FLIGHT=()
DESC=""
# Sets DESC rather than printing it: this must run in the main shell, because a
# command substitution is a subshell and would lose the IN_FLIGHT update.
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

usage() {
  {
    echo "ERROR: $1"
    echo
    echo "  Usage:    gmake canary-${ACTION} SVC=service-1"
    echo "  Services: service-1 or service-2. Promote service-2 first: service-1 calls it."
    echo
    echo "  Rollouts in ${NAMESPACE} right now:"
    for s in "${SERVICES[@]}"; do describe "$s"; echo "    $s   $DESC"; done
    echo
    echo "  Run gmake canary-${ACTION} with no SVC in a terminal to be asked instead."
  } >&2
  exit 1
}

PICKED=0
if [[ -z "$SVC" ]]; then
  if [[ ! -t 0 ]]; then usage "SVC is required: the service whose prod rollout to act on."; fi
  echo
  case "$ACTION" in
    status)  echo "Which service do you want to watch?" ;;
    promote) echo "Which service do you want to promote?" ;;
    abort)   echo "Which service do you want to abort?" ;;
  esac
  i=1
  for s in "${SERVICES[@]}"; do
    describe "$s"
    printf '  %d) %-10s %s\n' "$i" "$s" "$DESC"
    i=$((i + 1))
  done

  # Default: the one thing in flight. When both are and we are promoting, service-2
  # goes first because service-1 calls it.
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
  fi
  echo
  if [[ -n "$DEFAULT" ]]; then
    read -r -p "Choose a number or type the name [Enter for ${DEFAULT}, q to cancel]: " choice
    [[ -z "$choice" ]] && choice="$DEFAULT"
  else
    read -r -p "Choose a number or type the name (Enter to cancel): " choice
    [[ -n "$choice" ]] || { echo "Cancelled. Nothing changed."; exit 1; }
  fi
  [[ "$choice" == "q" ]] && { echo "Cancelled. Nothing changed."; exit 1; }
  if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#SERVICES[@]} ]]; then
    SVC="${SERVICES[$((choice - 1))]}"
  else
    SVC="$choice"
  fi
  PICKED=1
fi

if [[ " ${SERVICES[*]} " != *" $SVC "* ]]; then
  usage "SVC must be one of: ${SERVICES[*]} (got '$SVC')."
fi

# promote and abort change what is serving traffic, so when the service was
# chosen from a menu, confirm. Naming SVC on the command line is already a
# deliberate act and behaves as it always did. YES=1 skips this too.
if [[ "$PICKED" -eq 1 && "$ACTION" != "status" && "${ASSUME_YES:-}" != "1" ]]; then
  echo
  IN_FLIGHT=(); describe "$SVC"
  echo "  $SVC: $DESC"
  case "$ACTION" in
    promote) echo "  Promoting finishes the rollout: the new build takes all the traffic." ;;
    abort)   echo "  Aborting scales the canary to zero. Stable keeps serving, and Git still points at the new build." ;;
  esac
  read -r -p "Go ahead and ${ACTION} $SVC? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled. Nothing changed."; exit 1; }
fi

case "$ACTION" in
  status)
    echo "Watching $SVC. Ctrl-C stops watching and does not affect the rollout."
    echo "When it shows Paused: gmake canary-promote SVC=$SVC   or   gmake canary-abort SVC=$SVC"
    exec kubectl argo rollouts get rollout "$SVC" -n "$NAMESPACE" --context "$CONTEXT" --watch
    ;;
  promote)
    kubectl argo rollouts promote "$SVC" -n "$NAMESPACE" --context "$CONTEXT"
    echo
    echo "Promoted. Watch it finish: gmake canary-status SVC=$SVC"
    echo "If both services are in this release, promote service-2 before service-1."
    ;;
  abort)
    kubectl argo rollouts abort "$SVC" -n "$NAMESPACE" --context "$CONTEXT"
    echo
    echo "Canary removed from service. Stable is unaffected."
    echo "This does NOT undo the release: Git still points prod at the bad tag,"
    echo "so the next sync will try again. Revert the release PR to make it stick."
    ;;
esac
