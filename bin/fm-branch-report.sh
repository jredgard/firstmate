#!/usr/bin/env bash
# fm-branch-report.sh - the supervision branch's report surface off Pi: the
# command twin of the Pi branch extension's fm_branch_report tool, for a
# branch session run by the supervision host (docs/supervision-host.md).
#
# It records exactly one handled fleet event in the durable outcome store
# (bin/fm-branch-outcome.sh owns the store) and gives the host the receipt it
# requires before it counts a wake handled. It enforces the same scoping the
# Pi tool does (docs/pi-supervision-branch.md "Components and their owners"):
# while the host's current turn claims signal or stale rows, only the tasks
# those rows resolve to may be reported - `fleet` and any remembered task are
# refused before the store is touched - and a claim that names no task (a
# heartbeat review, or a claimed heartbeat or check row) is unscoped. The
# claimed task set comes from .pi/extensions/lib/fm-branch-dispatch.ts through
# the host's turn record; this script only compares against it.
#
# Usage:
#   fm-branch-report.sh --task <id|fleet> --verdict routine|captain \
#       --summary <text> [--silent true|false] [--wake <text>] \
#       [--main-action auto|dispatch|decision|captain-hold|already-closed]
#
# The verdict criteria are owned by bin/fm-branch-prompt.sh ("Verdict: routine
# or captain"); --silent true is legal only for a routine outcome.
# --wake defaults to the wake reason the host recorded for the turn.
# --main-action applies only to an away host turn while still away. auto
# (the default) hands a granted merge-landed check for the task, a newly
# presented done or failed event, or a removed scoped task record to MAIN for
# dispatch, and a newly presented needs-decision or blocked event that remains
# open for decision handling. The turn record captures every granted check
# payload and unread signal event before the engine drains them.
# dispatch also names cleanup or a worker stopped as idle after readiness,
# including an action found on heartbeat; decision names input the engine
# declines; captain-hold explicitly leaves a genuinely captain-owned call for
# return.
# already-closed records a routine merged-PR sweep note without handing back:
# the turn must have captured closed-task=<id> before handling, the task record
# must still be absent, and its granted check must name that task's merged PR.
# It refuses for a task removed during this turn, so successful cleanup still
# hands back the freed slot. It is away-host-only and requires a rendered routine verdict.
# New terminal events hand back even when captain-hold was requested;
# standing lane status never triggers a handback.
# A derived dispatch handback is queued once per turn and task; an explicit
# dispatch or decision always queues its own.
# A handback is a durable check row keyed supervision-host-handback:<seq>,
# published before acknowledgement, plus a fifth receipt column naming its
# action. Its payload names the lane and triggering event: done, failed, merge
# landed, teardown, or the open decision's verb and key (else decision); a
# terminal event never relabels an explicit decision. The host exits to MAIN after releasing the turn's leases; a later
# park passes that queued row to MAIN without offering it to another engine.
# Outcomes remain unprocessed for the return brief; this adds no merge or
# dispatch authority and changes no spend limit.
#
# Only the branch actor of a live host turn may report: FM_SUPERVISION_ACTOR
# must be "branch" and FM_BRANCH_REPORT_TURN must name the host's current turn
# record ($STATE/.supervision-host-turn), so a report typed after its turn
# ended, or from any other shell, is refused. Exit codes: 0 recorded, 1 the
# store refused or failed (nothing recorded), 2 usage, 3 refused (actor, turn,
# or scope).
#
# A non-silent row an away turn recorded after the captain returned (the turn
# record says posture=away, or predates the posture field, and no away record
# remains: none, or quiet mode's, whose captain is present; bin/fm-afk-contract.sh
# AWAY OR QUIET) may be missing from the return brief, so it is also queued
# for MAIN as a durable check wake keyed supervision-host-return:<seq>,
# presented by the drain until MAIN acknowledges it. bin/fm-afk-return.sh
# archives the record before it reads the store and this check follows the
# append, so every visible row is in the brief, queued, or both: the relay does
# not depend on the host surviving its turn or on its owner delivering the
# host's own handback. Silent outcomes remain in the store but are not queued
# or relayed as notes. An attended or quiet turn queues nothing, because its
# captain is present: its captain rows reach MAIN through the host's
# branch-outcome exit and the drain's BRANCH OUTCOMES section
# (bin/fm-wake-drain.sh), and its routine rows stay in the store.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

usage() {
  sed -n '/^# Usage:/,/^# --wake/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'report refused: %s\n' "$1" >&2
  exit 3
}

TASK='' VERDICT='' SUMMARY='' SILENT=false WAKE='' WAKE_SET=0 MAIN_ACTION=auto
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || usage ;;
    --verdict) VERDICT=${2:-}; shift 2 || usage ;;
    --summary) SUMMARY=${2:-}; shift 2 || usage ;;
    --silent) SILENT=${2:-}; shift 2 || usage ;;
    --wake) WAKE=${2:-}; WAKE_SET=1; shift 2 || usage ;;
    --main-action) MAIN_ACTION=${2:-}; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

TASK=$(printf '%s' "$TASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
SUMMARY=$(printf '%s' "$SUMMARY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$TASK" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case "$VERDICT" in routine|captain) ;; *) VERDICT= ;; esac
case "$SILENT" in true|false) ;; *) usage ;; esac
case "$MAIN_ACTION" in auto|dispatch|decision|captain-hold|already-closed) ;; *) usage ;; esac
if [ "$SILENT" = true ]; then
  case "$MAIN_ACTION" in dispatch|decision) usage ;; esac
fi
if [ -z "$TASK" ] || [ -z "$SUMMARY" ] || [ -z "$VERDICT" ]; then
  echo "invalid report: --task, --verdict (routine|captain), and --summary are required" >&2
  exit 2
fi
if [ "$SILENT" = true ] && [ "$VERDICT" != routine ]; then
  echo "invalid report: --silent true requires the routine verdict" >&2
  exit 2
fi

[ "${FM_SUPERVISION_ACTOR:-}" = branch ] \
  || refuse "only the supervision branch reports outcomes; MAIN acts on them instead"
TURN=${FM_BRANCH_REPORT_TURN:-}
case "$TURN" in
  ''|*[!A-Za-z0-9._-]*) refuse "no supervision wake is being handled by this shell" ;;
esac

turn_field() {  # <name>
  sed -n "s/^$1=//p" "$TURN_FILE" 2>/dev/null | head -n 1
}

[ -f "$TURN_FILE" ] && [ ! -L "$TURN_FILE" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"
[ "$(turn_field turn)" = "$TURN" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"

if [ "$(turn_field unscoped)" != 1 ]; then
  TASKS=$(turn_field tasks)
  case " $TASKS " in
    *" $TASK "*) ;;
    *)
      refuse "the wake being handled (row $(turn_field rows)) names ${TASKS:-no task}, not $TASK; report only that task, never fleet or a task from memory"
      ;;
  esac
fi

[ "$WAKE_SET" -eq 1 ] || WAKE=$(turn_field wake)

# Host-only routing: never infer an action from the free-text outcome summary
# or parse the captain's mandate. Shared status readers own open decisions.
if [ "$MAIN_ACTION" = already-closed ]; then
  if ! { [ "$(turn_field posture)" = away ] && fm_afk_contract_away_present "$STATE" \
    && [ "$VERDICT" = routine ] && [ "$SILENT" = false ] && [ ! -e "$STATE/$TASK.meta" ] \
    && [ ! -L "$STATE/$TASK.meta" ] \
    && grep -Fxq "closed-task=$TASK" "$TURN_FILE" \
    && awk -v task="$TASK" 'index($0, "check=check: merge landed: " task " ") == 1 { found=1 } END { exit !found }' "$TURN_FILE"; }; then
    refuse "already-closed requires a routine merged-PR sweep for a task absent before and after handling"
  fi
fi
ACTION=none
if [ "$(turn_field posture)" = away ] && fm_afk_contract_away_present "$STATE"; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  ACTION=$MAIN_ACTION
  STATUS="$STATE/$TASK.status"
  TRIGGER=''
  case "$ACTION" in
    dispatch) TRIGGER=teardown ;;
    decision) TRIGGER=decision ;;
  esac
  TERMINAL_EVENT=''
  if awk -v task="$TASK" 'index($0, "check=check: merge landed: " task " ") == 1 { found=1 } END { exit !found }' "$TURN_FILE"; then
    TERMINAL_EVENT='merge landed'
  fi
  EVENTS=$(awk -F '\t' -v task="$TASK" '$1 == "event=" task { sub(/^[^\t]*\t/, ""); print }' "$TURN_FILE")
  if [ "$TASK" != fleet ]; then
    while IFS= read -r EVENT; do
      VERB=$(status_line_verb "$EVENT")
      case "$VERB" in "done"|failed) TERMINAL_EVENT=$VERB ;; esac
    done <<EOF
$EVENTS
EOF
    case " $(turn_field tasks) " in
      *" $TASK "*) [ -e "$STATE/$TASK.meta" ] || TERMINAL_EVENT=teardown ;;
    esac
  fi
  if [ "$MAIN_ACTION" = already-closed ]; then
    ACTION=none
  elif [ -n "$TERMINAL_EVENT" ] && [ "$ACTION" != decision ]; then
    ACTION=dispatch
    TRIGGER=$TERMINAL_EVENT
    if [ "$MAIN_ACTION" != dispatch ] && [ -f "$RECEIPTS" ] \
      && awk -F '\t' -v turn="$TURN" -v task="$TASK" \
        '$1 == turn && $4 == task && $5 == "dispatch" { found=1 } END { exit !found }' "$RECEIPTS"; then
      ACTION=none
    fi
  elif [ "$ACTION" = auto ] || [ "$ACTION" = decision ]; then
    [ "$ACTION" != auto ] || ACTION=none
    OPEN=$(status_open_decisions "$STATUS")
    if [ "$MAIN_ACTION" = decision ]; then
      while IFS=$'\t' read -r KEY VERB _; do
        [ -z "$VERB" ] || TRIGGER="$VERB [key=$KEY]"
      done <<EOF
$OPEN
EOF
    fi
    while IFS= read -r EVENT; do
      VERB=$(status_line_verb "$EVENT")
      case "$VERB" in needs-decision|blocked) ;; *) continue ;; esac
      KEY=$(_fm_decision_key "$EVENT") || continue
      DECISION=$(printf '%s\t%s\t%s' "$KEY" "$VERB" "$(status_line_note "$EVENT")")
      case $'\n'"$OPEN"$'\n' in
        *$'\n'"$DECISION"$'\n'*) ACTION=decision; TRIGGER="$VERB [key=$KEY]" ;;
      esac
    done <<EOF
$EVENTS
EOF
  fi
fi

set -- append --task "$TASK" --verdict "$VERDICT" --summary "$SUMMARY" --silent "$SILENT"
[ -z "$WAKE" ] || set -- "$@" --wake "$WAKE"
if ! SEQ=$("$SCRIPT_DIR/fm-branch-outcome.sh" "$@"); then
  echo "outcome store append failed (nothing recorded)" >&2
  exit 1
fi
case "$ACTION" in
  dispatch|decision)
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check "supervision-host-handback:$SEQ" \
      "check: supervision-host handback: $ACTION for $TASK (outcome $SEQ), event $TRIGGER: $SUMMARY" || {
      echo "recorded seq $SEQ, but its MAIN handback could not be queued" >&2
      exit 1
    }
    ;;
esac
if [ "$ACTION" = none ]; then
  RECEIPT=$(printf '%s\t%s\t%s\t%s' "$TURN" "$SEQ" "$VERDICT" "$TASK")
else
  RECEIPT=$(printf '%s\t%s\t%s\t%s\t%s' "$TURN" "$SEQ" "$VERDICT" "$TASK" "$ACTION")
fi
printf '%s\n' "$RECEIPT" >> "$RECEIPTS" || {
  echo "recorded seq $SEQ, but the host receipt could not be written; the host will hand this wake to MAIN" >&2
  exit 1
}
if [ "$SILENT" = true ]; then
  printf 'recorded seq %s [routine]; silent outcome remains in the outcome store\n' "$SEQ"
  exit 0
fi
case "$(turn_field posture)" in
  attended|quiet)
    if [ "$VERDICT" = captain ] && ! fm_afk_contract_away_present "$STATE"; then
      printf 'recorded seq %s [captain]; MAIN processes it from its next drain\n' "$SEQ"
    else
      printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
    fi
    exit 0
    ;;
esac
if ! fm_afk_contract_away_present "$STATE"; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_wake_append check "supervision-host-return:$SEQ" \
    "check: supervision-host outcome $SEQ for $TASK [$VERDICT] was recorded after the captain returned, so the return brief may not show it; relay it to the captain: $SUMMARY"; then
    printf 'recorded seq %s [%s], but the captain has returned and its relay to MAIN could not be queued; the host hands this turn to MAIN\n' "$SEQ" "$VERDICT" >&2
    exit 0
  fi
  printf 'recorded seq %s [%s]; the captain has returned, so it is queued for MAIN to relay\n' "$SEQ" "$VERDICT"
  exit 0
fi
printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
