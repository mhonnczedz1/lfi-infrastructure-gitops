#!/usr/bin/env bash
# Shared prompts for the gmake commands. Sourced by the scripts, never run.
#
# Every command asks the same few questions in the same way:
#   which cluster   local (k3d-platform), eks (lfi-eks), or both where it makes sense
#   which service   service-1, service-2, or both where it makes sense
#   which stage     dev, prod, or both
#
# A question is skipped when its variable is already set, so the same command
# works interactively and in a script:
#   gmake release                              asks everything
#   gmake release CLUSTER=eks SVC=service-1    asks nothing
# With no terminal (a pipe, CI) a missing answer is an error with a hint, never
# a prompt that waits forever.
#
# Variables the questions read: CLUSTER, SVC, ENVIRONMENT, ACTION. The answers
# land in arrays: PICKED_CLUSTERS, PICKED_SERVICES, PICKED_STAGES.
# After a prompted run, show_equivalent prints the command that would have
# skipped the questions, so the interactive form teaches the scripted one.

LFI_CLUSTERS=(local eks)
LFI_SERVICES=(service-1 service-2)
LFI_STAGES=(dev prod)

PICKED_CLUSTERS=()
PICKED_SERVICES=()
PICKED_STAGES=()
EQUIV=""        # grows as questions are answered, e.g. " CLUSTER=eks SVC=service-1"

is_tty() { [[ -t 0 ]]; }

cancel() {
  echo "Cancelled. Nothing changed." >&2
  exit 1
}

# usage_error <message> [example...]: the standard "you need to say what" exit.
usage_error() {
  {
    echo "ERROR: $1"
    shift
    if [[ $# -gt 0 ]]; then
      echo
      echo "  Examples:"
      for line in "$@"; do echo "    $line"; done
    fi
  } >&2
  exit 1
}

cluster_context() {
  case "$1" in
    local) echo "k3d-platform" ;;
    eks)   echo "lfi-eks" ;;
    *)     return 1 ;;
  esac
}

cluster_title() { echo "$1 ($(cluster_context "$1"))"; }

# "running" when ArgoCD's namespace answers, otherwise "not reachable". The short
# timeout keeps a menu from hanging on a cluster that is stopped or gone.
cluster_state() {
  if kubectl --context "$(cluster_context "$1")" --request-timeout=4s get ns argocd >/dev/null 2>&1; then
    echo "running"
  else
    echo "not reachable"
  fi
}

# Read one line, with an optional default taken on Enter. "q" always cancels.
# Sets REPLY_VALUE.
ask() { # <prompt> [default]
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [Enter = $default, q = cancel]: " answer
    [[ -z "$answer" ]] && answer="$default"
  else
    read -r -p "$prompt [q = cancel]: " answer
    [[ -z "$answer" ]] && cancel
  fi
  [[ "$answer" == "q" ]] && cancel
  REPLY_VALUE="$answer"
}

# confirm <question>: y/N, skipped by ASSUME_YES=1 (YES=1 in the Makefile).
confirm() {
  [[ "${ASSUME_YES:-}" == "1" ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || cancel
}

# pick_generic <noun> <question> <allow_both> <given> <default> <values...>
# The shared menu. The caller defines menu_label and menu_note (what to show
# beside each value). Sets PICKED (array) and PICKED_CHOICE. A value already in
# <given> skips the menu, and is checked against the same list.
pick_generic() {
  local noun="$1" question="$2" allow_both="$3" given="$4" default="$5"; shift 5
  local values=("$@") valid=("$@") v choice i=1
  [[ "$allow_both" == yes ]] && valid+=(both)
  PICKED=()

  if [[ -n "$given" ]]; then
    choice="$given"
  else
    is_tty || usage_error "${noun} is required (one of: ${valid[*]})."
    echo
    echo "$question"
    for v in "${values[@]}"; do
      printf '  %d) %-24s %s\n' "$i" "$(menu_label "$v")" "$(menu_note "$v")"
      i=$((i + 1))
    done
    if [[ "$allow_both" == yes ]]; then
      printf '  %d) %-24s %s\n' "$i" "both" "$(menu_note both)"
    fi
    ask "Choose a number or name" "$default"
    choice="$REPLY_VALUE"
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#valid[@]} ]]; then
      choice="${valid[$((choice - 1))]}"
    fi
  fi

  local ok=0
  for v in "${valid[@]}"; do [[ "$choice" == "$v" ]] && ok=1; done
  [[ "$ok" -eq 1 ]] || usage_error "'${choice}' is not a valid ${noun}. Choose one of: ${valid[*]}."

  if [[ "$choice" == "both" ]]; then PICKED=("${values[@]}"); else PICKED=("$choice"); fi
  PICKED_CHOICE="$choice"
}

# pick_cluster <what you are about to do> <allow_both> [prefer_running]
# With prefer_running, Enter takes the one cluster that is up, if only one is.
pick_cluster() {
  local what="$1" allow_both="$2" prefer="${3:-}" default="" c
  local running=()
  if [[ -z "${CLUSTER:-}" ]]; then
    # Ask each cluster once, before the menu. Stored as STATE_local, STATE_eks:
    # bash 3.2 on macOS has no associative arrays.
    for c in "${LFI_CLUSTERS[@]}"; do
      printf -v "STATE_${c}" '%s' "$(cluster_state "$c")"
      [[ "$(cluster_state_of "$c")" == "running" ]] && running+=("$c")
    done
    if [[ "$prefer" == "running" && ${#running[@]} -eq 1 ]]; then default="${running[0]}"; fi
  fi
  menu_label() { cluster_title "$1"; }
  menu_note() {
    case "$1" in
      both) echo "local first, then eks" ;;
      *)    cluster_state_of "$1" ;;
    esac
  }
  pick_generic "cluster" "Which cluster do you want to ${what}?" "$allow_both" "${CLUSTER:-}" "$default" "${LFI_CLUSTERS[@]}"
  PICKED_CLUSTERS=("${PICKED[@]}")
  [[ -z "${CLUSTER:-}" ]] && EQUIV+=" CLUSTER=${PICKED_CHOICE}"
  return 0
}

cluster_state_of() { local v="STATE_$1"; echo "${!v:-}"; }

# pick_service <what you are about to do> <allow_both>
pick_service() {
  local what="$1" allow_both="$2"
  menu_label() { echo "$1"; }
  menu_note() {
    case "$1" in
      service-1) echo "the gateway. Calls service-2." ;;
      service-2) echo "the worker. Release and promote it first." ;;
      both)      echo "service-1 and service-2" ;;
    esac
  }
  pick_generic "service" "Which service do you want to ${what}?" "$allow_both" "${SVC:-}" "" "${LFI_SERVICES[@]}"
  PICKED_SERVICES=("${PICKED[@]}")
  [[ -z "${SVC:-}" ]] && EQUIV+=" SVC=${PICKED_CHOICE}"
  return 0
}

# pick_stage <what you are about to do> <allow_both>
pick_stage() {
  local what="$1" allow_both="$2"
  menu_label() { echo "$1"; }
  menu_note() {
    case "$1" in
      dev)  echo "follows every build automatically" ;;
      prod) echo "changes only when a release PR is merged" ;;
      both) echo "dev and prod" ;;
    esac
  }
  pick_generic "environment" "Which environment do you want to ${what}?" "$allow_both" "${ENVIRONMENT:-}" "" "${LFI_STAGES[@]}"
  PICKED_STAGES=("${PICKED[@]}")
  [[ -z "${ENVIRONMENT:-}" ]] && EQUIV+=" ENVIRONMENT=${PICKED_CHOICE}"
  return 0
}

# show_equivalent <command>: only when a question was actually asked.
show_equivalent() {
  [[ -n "$EQUIV" ]] || return 0
  echo
  echo "Same thing without the questions:  $1$EQUIV"
}

# next_steps <line>...: where to go from here, printed last.
next_steps() {
  echo
  echo "Next:"
  for line in "$@"; do echo "  $line"; done
}
