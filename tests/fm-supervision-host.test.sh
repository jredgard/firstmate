#!/usr/bin/env bash
# Behavior tests for the supervision host loop (stub engine, both postures, wakes, closes, mirror, return)
# (bin/fm-supervision-host.sh, docs/supervision-host.md). Shared fixtures live
# in tests/supervision-host-helpers.sh.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_park_exit_probe_uses_half_second_child_sleeps() {
  local home host_pid
  home=$(make_home park-cadence attended)
  cat > "$home/fakebin/sleep" <<'SH'
#!/bin/bash
pid=''
if [ -f "$FM_HOME/probe-host" ]; then
  IFS= read -r pid < "$FM_HOME/probe-host" || true
  if [ "$PPID" = "$pid" ]; then
    printf '%s\n' "$1" >> "$FM_HOME/park-sleeps"
  fi
fi
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/sleep"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "park-cadence: no watcher started"
  host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$host_pid" ] || fail "park-cadence: no recorded host"
  printf '%s\n' "$host_pid" > "$home/probe-host"
  wait_until 100 test -s "$home/park-sleeps" || fail "park-cadence: no child sleep observed"
  [ "$(sort -u "$home/park-sleeps")" = 0.5 ] || fail "park-cadence: exit probing did not use half-second sleeps"
  stop_home_processes "$home"
  pass "host: parked child-exit sampling uses ordinary half-second sleeps"
}

test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main() {
  local home first drained
  home=$(make_home attended-routine attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "attended: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 \
    || fail "attended: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the attended engine must run as the branch actor"
  assert_no_grep 'MODULE_TYPELESS_PACKAGE_JSON' "$home/state/.supervision-host.log" "attended dispatch must keep module-type warnings out of the ledger"
  assert_no_re '^POSTURE: AWAY' "$first" "an attended wake must carry no away tail"
  assert_re '^(arg=)?FIRSTMATE SUPERVISION WAKE: signal: ' "$first" "the attended wake must carry the close"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "the engine's routine report did not reach the store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended report must queue no return wake for main"
  assert_grep 'it waits in the outcome store for MAIN' "$home/engine-report.log" "an attended routine report must say it stays in the store"
  [ ! -s "$home/host.rc" ] || fail "a routine attended outcome reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a routine attended outcome printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor after an attended wake"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES, ROUTINE (handled by the supervision session since your last drain" \
    "main's next drain must list the routine outcome for awareness"
  assert_contains "$drained" "[seq 1] demo: stub handled demo" "the routine listing must carry the outcome"
  assert_not_contains "$drained" "mark-processed" "a routine outcome must ask for no acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "[seq 1]" "a routine outcome must be listed only once"
  pass "host: an attended wake the branch may take is handled on the engine, and its routine outcome never wakes main"
}


# A TERM that lands just after a handled wake, while the host settles its
# successor handoff under the queue and marker locks, must not leave the host
# waiting in its own exit cleanup on the queue lock it still holds: that wedged
# the host (and every later queue append) instead of exiting.

test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue() {
  local home pid
  home=$(make_home handled-then-term attended)
  echo hold-marker > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "handled then TERM: the host never started a watcher cycle"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 \
    || fail "handled then TERM: the wake was not handled on the engine: $(cat "$home/state/.supervision-host.log")"
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$pid" ] || fail "fixture: no host record after the handled wake"
  kill -TERM "$pid" 2>/dev/null || true
  wait_until 100 bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid" \
    || fail "handled then TERM: the host did not exit within 10s of TERM after a handled wake"
  FM_HOME="$home" timeout 10 bash -c '. "$1"; fm_wake_append check probe "check: probe"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "handled then TERM: the stopped host left the wake queue lock held"
  stop_home_processes "$home"
  pass "host: a host stopped right after a handled wake exits and leaves the wake queue usable"
}


# A wrapper may launch the engine in another time zone than the host's (one
# observed wrapper exports a TZ the main session's hooks never see). The
# process-table identity that ties the branch grant to the host must read the
# same from both, or the engine's drain discards the grant as stale, refuses,
# and leaves every granted row for main. The proc root is hidden so Linux takes
# the same process-table path as macOS.

test_engine_in_another_time_zone_handles_its_granted_rows() {
  local home no_proc
  home=$(make_home engine-tz attended)
  no_proc="$TMP_ROOT/engine-tz-no-proc"
  [ "$(TZ=UTC0 LC_ALL=C ps -p $$ -o lstart=)" != "$(TZ=ENG-9 LC_ALL=C ps -p $$ -o lstart=)" ] \
    || fail "fixture: ps renders the same start time in both time zones, so the case would prove nothing"
  printf 'ENG-9\n' > "$home/stub-tz"
  TZ=UTC0 FM_PROC_ROOT_OVERRIDE="$no_proc" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "engine tz: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "engine tz: the turn did not end handled: $(cat "$home/state/.supervision-host.log"; cat "$home"/engine-drain.* 2>/dev/null)"
  assert_no_re '	failed	' "$home/state/.supervision-host.log" "engine tz: a turn that reported for its granted rows must not fail"
  assert_no_grep 'no branch-eligible row snapshot' "$home/engine-drain.1" "engine tz: the engine's drain discarded the host's grant"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "engine tz: the engine's acknowledgement did not consume the wake"
  [ ! -s "$home/host.rc" ] || fail "engine tz: the handled wake reached main: $(cat "$home/host.out")"
  pass "host: an engine in another time zone than the host drains, reports, and acknowledges its granted rows"
}

test_attended_captain_outcome_reaches_main_through_branch_outcomes() {
  local home drained
  home=$(make_home attended-captain attended)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "captain: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "captain: the captain outcome did not wake main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a captain-outcome exit must exit 0 for the owner to deliver"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row and send main to its drain"
  assert_no_re '^signal:' "$home/host.out" "the close the engine handled must not reach main as a wake"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "an attended captain report must say main processes it"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended captain report must queue no return wake"
  watcher_live "$home" && fail "the host left its successor cycle running when it woke main"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome"
  assert_contains "$drained" "[seq 1, recorded " "the section must carry the outcome's row and when it was recorded"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome's task and summary"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 1" "the section must print its exact acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub escalated: " "an unacknowledged captain outcome must be presented again"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null \
    || fail "main's acknowledgement of the presented outcome was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged captain outcome must not be presented again"
  pass "host: an attended captain outcome wakes main once and stays in its drain until main acknowledges it"
}

test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return() {
  local home drained
  home=$(make_home attended-go-away attended)
  echo go-away > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "go-away: the host never started a watcher cycle"
  append_status "$home" 'finished while the captain left'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "go-away: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  [ -f "$home/state/.afk-contract" ] || fail "fixture: the stub did not record the away posture"
  [ ! -s "$home/host.rc" ] || fail "a captain outcome recorded after the captain left woke main: $(cat "$home/host.out")"
  assert_grep '"verdict":"captain"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report a captain outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "captain outcomes must wait for the return while the away record exists"
  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub handled demo" "after the return the drain must present the away window's captain outcome"
  pass "host: a captain outcome recorded after the captain left waits for the return, then reaches main's drain"
}


# A quiet record left without its daemon (no state/.afk) is a present captain,
# not an away one: the host runs attended beside it, so a captain outcome wakes
# main and reaches its drain instead of waiting for a return that never comes,
# and a decision close reaches main as the plain arm delivers it.

test_quiet_record_without_its_daemon_is_a_present_captain() {
  local home drained
  home=$(make_home quiet-captain quiet)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "quiet: the captain outcome did not wake the present captain's main: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a wordless quiet record must leave the host's turn attended"
  assert_no_re '^POSTURE: AWAY' "$home/engine-call.1" "a turn beside a quiet record must carry no away tail"
  assert_re 'MAIN DIALOG MIRROR' "$home/engine-call.1" "a turn beside a quiet record must carry the captain's dialog"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "a captain report beside a quiet record must say main processes it"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row for the present captain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome beside a quiet record"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome"
  [ -f "$home/state/.afk-contract" ] || fail "the host must leave quiet mode's record in place"

  home=$(make_home quiet-main-only quiet)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "quiet main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_re '^signal: .*demo.status' "$home/host.out" "the decision close must reach main as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "quiet main-only: the engine took a decision close from a present captain"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record the attended main-only pass-through"
  pass "host: a quiet record without its daemon is a present captain, so outcomes and decisions reach main"
}

test_attended_main_only_close_passes_straight_to_main() {
  local home
  home=$(make_home attended-main-only attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "main-only: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  pass "host: an attended decision close stays main's exactly as the plain arm delivers it"
}


# The file is read at every wake (docs/configuration.md "Supervision host"), so
# an off written while the host is parked sends the next attended close to main
# exactly as the arm printed it, with the ledger naming the opt-out.

test_off_written_while_parked_passes_the_next_attended_close_to_main() {
  local home
  home=$(make_home attended-off-while-parked attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "off while parked: the host never started a watcher cycle"
  : > "$home/config/supervision-host-off"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "off while parked: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close on a home that opted out must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "off while parked: the engine ran after the home opted out"
  assert_re '	pass-through	attended	the home does not run the supervision host	signal:' "$home/state/.supervision-host.log" \
    "the ledger must name the opt-out as why the close went to main"
  stop_home_processes "$home"
  pass "host: an off written while the host is parked sends the next attended close to main, naming the opt-out"
}


# The live failure this guards: a main-only pass-through used to exit without
# a watcher, so nothing restarted short-lived listeners until the session
# armed again. The close still reaches main unchanged, and the successor
# cycle stays up for the session's next arm to attach to.

test_main_only_pass_through_leaves_the_successor_watcher_running() {
  local home pid
  home=$(make_home main-only-successor attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "successor: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "successor: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "successor: the engine ran for a decision close"
  watcher_live "$home" || fail "successor: the pass-through left no live watcher: $(cat "$home/state/.supervision-host.log")"
  [ "$(marker_kind "$home")" = downtime ] \
    || fail "successor: the pass-through claimed the close was being handled, so main's re-arm owner would not deliver it: $(cat "$home/state/.watcher-down")"
  pid=$(cat "$home/state/.watch.lock/pid")
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "successor: the watcher exited after the pass-through (pid $pid)"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] || fail "successor: the watcher lock moved after the pass-through"
  pass "host: a main-only pass-through leaves the successor watcher running and the close undelivered for main"
}


# The session-lock holder's process identity cannot be read (its proc entry
# is truncated), so no main-session key exists: the close reaches main exactly
# as the arm printed it, before any mirror feed or engine turn.

test_attended_close_with_unidentified_main_session_passes_to_main() {
  local home
  home=$(make_home attended-unidentified attended)
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      mkdir -p "$FM_HOME/proc/$$"
      printf "%s (claude) S\n" "$$" > "$FM_HOME/proc/$$/stat"
      printf "claude\0" > "$FM_HOME/proc/$$/cmdline"
      export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc"
      "$0" park > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "unidentified: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "unidentified: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close for an unidentified main session must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "unidentified: the engine ran without a main-session key"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_re '	pass-through	attended	the main session could not be identified	signal:' "$home/state/.supervision-host.log" \
    "the ledger must record why the close went to main"
  pass "host: an attended close whose main session cannot be identified reaches main and runs no engine turn"
}


# The captain returns after the loop accepted a decision close away but before
# its turn starts: the turn meets the attended rule, so the close still reaches
# main exactly as the arm printed it instead of being scoped to nothing.

test_close_accepted_away_that_turns_attended_passes_to_main() {
  local home real_mktemp
  home=$(make_home away-then-attended away)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  real_mktemp=$(command -v mktemp)
  # Starting the successor arm is the first step after the loop's away check;
  # once the decision line is queued, the captain returns there.
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    ! grep -q 'which export format?' "\$FM_HOME/state/demo.status" 2>/dev/null \
      || "\$FM_REPO/bin/fm-afk-contract.sh" archive >> "\$FM_HOME/engine-return.log" 2>&1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away-then-attended: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "away-then-attended: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_absent "$home/state/.afk-contract" "fixture: the captain did not return before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "away-then-attended: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  assert_no_re '	no-op	' "$home/state/.supervision-host.log" "the close must not be treated as handled"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: a decision close accepted away whose turn starts attended still reaches main unchanged"
}

test_attended_close_that_turns_main_only_before_its_turn_passes_to_main() {
  local home
  home=$(make_home attended-turns-main-only attended)
  turn_main_only_at_second_offer "$home" snapshot
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "turns-main-only: the host never started a watcher cycle"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "turns-main-only: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'which export format?' "$home/state/demo.status" "fixture: the decision was not recorded before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "turns-main-only: the engine ran on a stale offer"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_grep 'which export format?' "$home/pi-offer-state/demo.status" "fixture: the Pi snapshot must contain the new decision"
  assert_no_re 'needs-decision:' "$home/pi-offer-state/.wake-queue" "fixture: the Pi snapshot must contain only the accepted wake"
  local pi_offer
  pi_offer=$(node --input-type=module -e '
    const dispatch = await import(process.argv[1]);
    console.log(dispatch.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$home/pi-offer-state" "signal: $home/state/demo.status")
  [ "$pi_offer" = true ] || fail "the host-only transition veto changed Pi's existing offer rule"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: an attended close whose task turns main-only before its turn still reaches main unchanged"
}


# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.

test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    # The fork's slower CI runners need headroom for this host/engine wait.
    wait_until 450 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}


# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.

test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}


# Dialog counts as delivered only once the turn that carried it is accepted
# with its report. A host that reaches its park boundary after feeding the
# mirror but before the turn, or is stopped mid-turn, leaves the conversation
# resumable without it, so the next turn must still carry it; a turn with no
# report starts a new conversation, which must carry it too.

test_undelivered_dialog_is_fed_again_on_the_next_turn() {
  local home real_node second third fourth
  home=$(make_home mirror-boundary attended)
  real_node=$(command -v node)
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${3:-}" = wake-prompt ] && [ -e "\$FM_HOME/slow-render" ]; then echo 120 > "\$FM_HOME/park-clock"; fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"first ask"}' > "$home/mirror-seed.1"
  echo 0 > "$home/park-clock"
  # The park bound sits past every wall-clock check below, so a host that
  # ignored the test clock could never reach a boundary inside this case.
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "mirror boundary: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] first ask$' "$home/engine-call.1" "fixture: the first turn did not carry the first dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the first host did not stop on TERM"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"second ask, never handed over"}' > "$home/mirror-seed.2"
  : > "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_after_stop "$home"
  append_status "$home" 'reaches the boundary'
  wait_until 400 host_exited "$home" || fail "mirror boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "fixture: the second host did not exit at its boundary"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "fixture: an engine turn ran at the boundary"
  main_drain_and_ack "$home"

  rm -f "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_again "$home"
  append_status "$home" 'handled after the boundary'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 2 || fail "mirror boundary: the next wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the next turn did not resume the conversation"
  assert_re '^\[captain\] second ask, never handed over$' "$second" \
    "dialog fed to a wake that never reached the engine must reach the next turn"
  assert_no_re '^\[captain\] first ask$' "$second" "a resumed conversation must not be fed dialog it already has"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p3","prompt":"third ask, turn stopped"}' > "$home/mirror-seed.3"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the second handling host did not stop on TERM"
  echo hang > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'stopped mid-turn'
  wait_until 250 test -e "$home/engine-call.3" || fail "mirror boundary: the stopped turn never started"
  assert_re '^\[captain\] third ask, turn stopped$' "$home/engine-call.3" "fixture: the stopped turn did not carry the third dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the host did not stop mid-turn on TERM"
  echo handle > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'handled after the stop'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 3 || fail "mirror boundary: the wake after the stop was not handled: $(cat "$home/state/.supervision-host.log")"
  third="$home/engine-call.4"
  assert_re '^arg=--resume$' "$third" "fixture: the turn after the stop did not resume the conversation"
  assert_re '^\[captain\] third ask, turn stopped$' "$third" "dialog of a turn stopped before its report must reach the next turn"
  assert_no_re '^\[captain\] second ask' "$third" "a resumed conversation must not be fed dialog a handled turn delivered"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p4","prompt":"fourth ask, turn unreported"}' > "$home/mirror-seed.4"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the third handling host did not stop on TERM"
  echo noreport > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'no report'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "mirror boundary: the unreported turn did not hand its wake back"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$home/engine-call.5" "fixture: the unreported turn did not carry the fourth dialog"
  main_drain_and_ack "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'handled after no report'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 4 || fail "mirror boundary: the wake after the unreported turn was not handled: $(cat "$home/state/.supervision-host.log")"
  fourth="$home/engine-call.6"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$fourth" "dialog of a turn that recorded no report must reach the next turn"
  pass "host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
}


# The attended engine never judges without the captain's words: a mirror that
# is missing, cannot be read, or holds an entry that does not parse hands the
# wake to main before any engine turn and leaves the mirror cursor where it was.

test_attended_wake_with_an_unreadable_mirror_reaches_main() {
  local home mirror cursor
  home=$(make_home attended-bad-mirror attended)
  mirror="$home/state/.host-mirror.jsonl"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "bad mirror: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  cursor=$(cat "$home/state/.host-mirror-cursor") || fail "fixture: the handled turn committed no mirror cursor"

  rm -f "$mirror"
  append_status "$home" 'missing mirror'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "bad mirror: a missing mirror did not hand the wake to main"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a missing mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a missing mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a missing mirror staged a cursor"
  main_drain_and_ack "$home"

  park_again "$home"
  [ -f "$mirror" ] || fail "fixture: the next park did not write the mirror again"
  chmod 000 "$mirror"
  append_status "$home" 'unreadable mirror'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "bad mirror: an unreadable mirror did not hand the wake to main"
  chmod 644 "$mirror"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "an unreadable mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a readable mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "an unreadable mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "an unreadable mirror staged a cursor"
  main_drain_and_ack "$home"

  printf '#!/usr/bin/env bash\nprev=\nfor a in "$@"; do [ "$prev" != --mirror-file ] || chmod 000 "$a"; prev=$a; done\nexec %q "$@"\n' \
    "$(command -v node)" > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  park_again "$home"
  append_status "$home" 'mirror lost before the prompt'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "bad mirror: a feed lost before the prompt did not hand the wake to main"
  rm -f "$home/fakebin/node"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a feed lost before the prompt must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without the feed it was promised"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a feed lost before the prompt moved the cursor"
  main_drain_and_ack "$home"

  printf '{"seq":' >> "$mirror"
  printf '\n' >> "$mirror"
  park_again "$home"
  append_status "$home" 'malformed mirror'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "bad mirror: a malformed mirror entry did not hand the wake to main"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a malformed mirror entry must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran past a malformed mirror entry"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a malformed mirror entry moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a malformed mirror entry staged a cursor past it"
  pass "host: an attended wake whose mirror is missing, cannot be read (at the feed or at the prompt), or holds a malformed entry reaches main before any engine turn, and the cursor stays put"
}

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_no_grep 'MODULE_TYPELESS_PACKAGE_JSON' "$home/state/.supervision-host.log" "away dispatch must keep module-type warnings out of the ledger"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until_deadline 60 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}


# Silent outcomes stay stored, but neither captain-return path names or relays
# them when the host decides whether to hand the wake to main.

test_silent_outcomes_are_not_relayed_when_the_captain_returns() {
  local mode home host
  for mode in return-silent return-fail-silent; do
    home=$(make_home "away-$mode" away)
    echo "$mode" > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$mode: the host never started a watcher cycle"
    append_status "$home" 'no-change result during a captain return'

    if [ "$mode" = return-silent ]; then
      # The fork's slower CI runners need headroom for this host/engine wait.
      wait_until 450 handled_at_least "$home" 1 || fail "$mode: the wake was not handled: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -s "$home/host.rc" ] || fail "$mode: a silent-only outcome forced a captain handoff: $(cat "$home/host.out")"
      watcher_live "$home" || fail "$mode: the host did not park on its successor"
      host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
      kill -TERM "$host"
      wait_until_deadline 60 host_exited "$home" || fail "$mode: the host did not stop on TERM"
    else
      # The fork's slower CI runners need headroom for this host/engine wait.
      wait_until 450 host_exited "$home" || fail "$mode: the failed turn did not hand the wake to main: $(cat "$home/host.out" 2>/dev/null) $(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null)"
      assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
        "$home/host.out" "$mode: the failed turn must still hand its wake to main"
    fi
    assert_no_re 'captain returned|store rows|^supervision-host: outcome ' "$home/host.out" \
      "$mode: a silent outcome was referenced in the captain-return handoff"
    assert_grep '"silent":true' "$home/state/branch-outcomes.jsonl" "$mode: the silent outcome was not retained in the store"
    assert_absent "$home/state/.afk-contract" "$mode: the captain return was not archived"
  done
  pass "host: silent outcomes are excluded from both captain-return handoff paths"
}

test_large_turn_relays_an_early_visible_outcome() {
  local home count
  home=$(make_home away-many-receipts away)
  echo return-many > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "many receipts: the host never started a watcher cycle"
  append_status "$home" 'large turn with a visible first outcome'
  wait_until_deadline 60 host_exited "$home" || fail "many receipts: the captain-return handoff did not finish: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(tail -n 5 "$home/engine-report.log" 2>/dev/null) rows=$(wc -l < "$home/state/branch-outcomes.jsonl" 2>/dev/null)"
  count=$(grep -c '^supervision-host: outcome ' "$home/host.out")
  [ "$count" -eq 1 ] || fail "many receipts: expected one visible outcome, got $count: $(tail -n 5 "$home/host.out")"
  [ "$(wc -l < "$home/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1001 ] \
    || fail "many receipts: the fixture did not exceed the old 1,000-row window: rows=$(wc -l < "$home/state/branch-outcomes.jsonl") host=$(cat "$home/host.out") report=$(cat "$home/engine-report.log") tail=$(tail -c 300 "$home/state/branch-outcomes.jsonl")"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "many receipts: the early visible outcome was lost behind later silent rows"
  assert_no_grep 'bulk silent fixture' "$home/host.out" "many receipts: silent outcomes were relayed"
  pass "host: an early visible outcome survives more than 1,000 same-turn receipts"
}

test_outcome_lookup_failure_is_not_treated_as_silence() {
  local home
  home=$(make_home away-lookup-failure away)
  echo return-lookup-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "lookup failure: the host never started a watcher cycle"
  append_status "$home" 'outcome lookup failure after a captain return'
  wait_until_deadline 60 host_exited "$home" || fail "lookup failure: the host treated an unreadable store as a silent outcome"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them$' \
    "$home/host.out" "lookup failure: the main handoff did not explain the lookup failure"
  assert_re '^supervision-host: outcome lookup failed for turn receipt rows 1; visible outcomes may require manual review$' \
    "$home/host.out" "lookup failure: the missing outcome warning was not emitted"
  pass "host: an outcome lookup failure forces a visible main handoff"
}


# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.

test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until_deadline 60 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}


# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.

test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  append_status "$home" 'mid-task, then a crash'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "return-fail: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

test_away_report_classifies_main_actions() {
  local home state scenario action expected out rows event trigger old_action old_wake wake_index rc
  for scenario in progress "done" failed merged teardown decision blocked decision-note blocked-note decision-explicit blocked-explicit decision-heartbeat resolved hold blocked-hold done-hold failed-hold heartbeat freed-slot teardown-due; do
    home=$(make_home "handback-report-$scenario" away)
    state="$home/state"
    printf 'turn=h1\nrows=1\ntasks=demo\nunscoped=0\nwake=signal: demo.status\nposture=away\n' > "$state/.supervision-host-turn"
    action=auto expected=none event='' trigger=''
    case "$scenario" in
      progress) printf 'working: rebased onto merged work; PR ready later\n' > "$state/demo.status" ;;
      done) event='done [at=1]: ready branch'; expected=dispatch; trigger="done" ;;
      failed) event='failed [at=1]: build broke'; expected=dispatch; trigger=failed ;;
      merged) printf 'turn=h1\nrows=1\ntasks=\nunscoped=1\nwake=check: merge landed: demo https://example.test/o/r/pull/1\nposture=away\ncheck=check: merge landed: demo https://example.test/o/r/pull/1\nmerged-task=demo\n' > "$state/.supervision-host-turn"; expected=dispatch; trigger='merge landed' ;;
      teardown) rm "$state/demo.meta"; expected=dispatch; trigger=teardown ;;
      decision) event='needs-decision [key=d1]: input needed'; expected=decision; trigger='needs-decision [key=d1]' ;;
      blocked) event='blocked [key=b1]: tooling refusal'; expected=decision; trigger='blocked [key=b1]' ;;
      decision-note) event='needs-decision: [key=d1] input needed'; expected=decision; trigger='needs-decision [key=d1]' ;;
      blocked-note) event='blocked: [key=b1] tooling refusal'; expected=decision; trigger='blocked [key=b1]' ;;
      decision-explicit) event='needs-decision [key=d1]: input needed'; action=decision; expected=decision; trigger='needs-decision [key=d1]' ;;
      blocked-explicit) event='blocked [key=b1]: tooling refusal'; action=decision; expected=decision; trigger='blocked [key=b1]' ;;
      decision-heartbeat)
        printf 'turn=h1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=away\n' > "$state/.supervision-host-turn"
        printf 'needs-decision [key=d1]: input needed\n' > "$state/demo.status"
        action=decision; expected=decision; trigger='needs-decision [key=d1]'
        ;;
      resolved) event='needs-decision [key=d1]: input needed' ;;
      hold) event='needs-decision [key=d1]: destructive choice'; action=captain-hold ;;
      blocked-hold) event='blocked [key=b1]: destructive choice'; action=captain-hold ;;
      done-hold) event='done: ready branch'; action=captain-hold; expected=dispatch; trigger="done" ;;
      failed-hold) event='failed: build broke'; action=captain-hold; expected=dispatch; trigger=failed ;;
      heartbeat) printf 'turn=h1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=away\n' > "$state/.supervision-host-turn" ;;
      freed-slot) printf 'turn=h1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=away\n' > "$state/.supervision-host-turn"; action=dispatch; expected=dispatch; trigger=teardown ;;
      teardown-due) action=dispatch; expected=dispatch; trigger=teardown ;;
    esac
    if [ -n "$event" ]; then
      printf '%s\n' "$event" > "$state/demo.status"
      printf 'event=demo\t%s\n' "$event" >> "$state/.supervision-host-turn"
      [ "$scenario" != resolved ] || printf 'resolved [key=d1]: answered\nworking: resumed\n' >> "$state/demo.status"
    fi
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
      --task demo --verdict captain --summary 'event handled' --main-action "$action" 2>&1) \
      || fail "$scenario: report failed: $out"
    rows=$(cat "$state/.wake-queue" 2>/dev/null || true)
    case "$expected" in
      none) assert_not_contains "$rows" 'supervision-host-handback:' "$scenario must remain held or routine" ;;
      *)
        assert_contains "$rows" "check: supervision-host handback: $expected for demo" "$scenario must hand back to MAIN"
        assert_contains "$rows" ", event $trigger: event handled" "$scenario must name the triggering event"
        [ "$(awk -F '\t' '{ print $5 }' "$state/.supervision-host-receipts")" = "$expected" ] \
          || fail "$scenario: receipt action missing"
        ;;
    esac
    assert_absent "$state/.branch-outcomes-processed" "$scenario must not process the return outcome"
    [ "$(FM_HOME="$home" "$CONTRACT" mode)" = away ] || fail "$scenario changed the away record"
  done
  home=$(make_home handback-invalid-none away)
  state="$home/state"
  printf 'turn=h1\nrows=1\ntasks=demo\nunscoped=0\nwake=signal: demo.status\nposture=away\n' > "$state/.supervision-host-turn"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
    --task demo --verdict routine --summary handled --main-action none 2>&1); rc=$?
  expect_code 2 "$rc" "none is no longer a report action"
  assert_absent "$state/branch-outcomes.jsonl" "a removed action must not record an outcome"
  assert_absent "$state/.supervision-host-receipts" "a removed action must not write a receipt"
  assert_absent "$state/.wake-queue" "a removed action must not queue a handback"
  for scenario in "done" failed decision blocked; do
    for old_action in auto captain-hold; do
      wake_index=0
      for old_wake in 'check: validation still running' 'stale: fm-demo' heartbeat 'signal: demo.turn-ended' 'signal: demo.status'; do
        wake_index=$((wake_index + 1))
        home=$(make_home "handback-old-$scenario-$old_action-$wake_index" away)
        state="$home/state"
        printf '%s [key=old]: old event\n' "${scenario/decision/needs-decision}" > "$state/demo.status"
        printf 'turn=h1\nrows=1\ntasks=demo\nunscoped=0\nwake=%s\nposture=away\n' "$old_wake" > "$state/.supervision-host-turn"
        printf 'event=demo\tworking: new routine event\n' >> "$state/.supervision-host-turn"
        out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
          --task demo --verdict captain --summary 'old event still held' --main-action "$old_action" 2>&1) \
          || fail "old $scenario/$old_action/$old_wake: report failed: $out"
        rows=$(cat "$state/.wake-queue" 2>/dev/null || true)
        assert_not_contains "$rows" 'supervision-host-handback:' "old $scenario must not hand back on $old_wake with $old_action"
      done
    done
  done
  pass "away reports: progress, resolved decisions and captain holds stay parked; terminal outcomes, freed slots and unanswered input hand back"
}

test_away_merge_handback_scopes_the_reported_lane() {
  local home state task out rows
  home=$(make_home handback-merge-scope away)
  state="$home/state"
  printf 'turn=h1\nrows=1 2\ntasks=\nunscoped=1\nwake=heartbeat\nposture=away\ncheck=check: merge landed: demo https://example.test/o/r/pull/1\nmerged-task=demo\n' > "$state/.supervision-host-turn"
  for task in demo dem demo-extra other fleet; do
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
      --task "$task" --verdict routine --summary "handled $task" 2>&1) \
      || fail "merge scope: $task report failed: $out"
  done
  rows=$(cat "$state/.wake-queue")
  assert_contains "$rows" 'handback: dispatch for demo (outcome 1)' "merge must hand back its lane"
  [ "$(awk -F '\t' '$3 == "check" && $4 ~ /^supervision-host-handback:/ { n++ } END { print n+0 }' "$state/.wake-queue")" = 1 ] \
    || fail "merge scope: unrelated reports queued extra handbacks: $rows"
  [ "$(awk -F '\t' '$5 == "dispatch" { print $4 }' "$state/.supervision-host-receipts")" = demo ] \
    || fail "merge scope: unrelated reports carried dispatch receipts"
  pass "away merge handback: only the exact reported lane receives a derived dispatch"
}

test_away_merge_handback_in_a_batch() {
  local home state out reason real_node
  real_node=$(command -v node)
  home=$(make_home handback-check-signal away)
  state="$home/state"
  echo handback-check > "$home/stub-mode"
  printf 'project=other\nwindow=fm-other\nharness=claude\n' > "$state/other.meta"
  mkfifo "$home/scope-release"
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${3:-}" = scope ] && [ ! -e "\$FM_HOME/scope-released" ]; then
  : > "\$FM_HOME/scope-ready"
  read -r _ < "\$FM_HOME/scope-release"
  : > "\$FM_HOME/scope-released"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  start_session "$home"
  park_again "$home"
  wait_until 150 watcher_live "$home" || fail "batch: watcher never started"
  printf 'working: other lane is running\n' > "$state/other.status"
  wait_until 250 sh -c '[ -e "$1" ]' _ "$home/scope-ready" || fail "batch: the host did not receive the first close"
  append_wake "$state" check validation 'check: validation still running'
  append_wake "$state" check merge 'check: merge landed: demo https://example.test/o/r/pull/1'
  printf 'release\n' > "$home/scope-release"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "batch: batched merge left MAIN parked"
  assert_grep 'check: validation still running' "$home/engine-drain.1" "the engine must receive other handled checks"
  assert_grep 'check: merge landed: demo' "$home/engine-drain.1" "the merge check must be granted"
  assert_grep "posture=away" "$state/.supervision-host.log" "the merge must be handled while away"
  reason=$(sed -n '/^supervision-host: away handback:/p' "$home/host.out")
  assert_contains "$reason" 'dispatch for demo (outcome 1), event merge landed:' "batched merge must name the correct lane and event"
  assert_not_contains "$reason" 'other.status' "the handled sibling must not reach MAIN"
  assert_grep "$(printf '\t')signal:" "$state/.supervision-host.log" "the merge must not be the first close line: $(cat "$state/.supervision-host.log")"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "batch: MAIN drain failed: $out"
  assert_contains "$out" 'handback: dispatch for demo (outcome 1), event merge landed:' "MAIN must receive the merge handback"
  assert_not_contains "$out" 'check: validation still running' "MAIN must not repeat handled checks"
  assert_not_contains "$out" 'other.status' "MAIN must not repeat the sibling lane"
  [ "$(awk -F '\t' 'NF >= 5 { n++ } END { print n+0 }' "$state/.wake-queue")" = 1 ] \
    || fail "batch: MAIN must receive only the handed lane"
  main_drain_and_ack "$home"
  [ "$(FM_HOME="$home" "$CONTRACT" mode)" = away ] || fail "batch: merge handback changed the away record"
  stop_home_processes "$home"
  pass "away batched merge: a sibling signal can precede the handed lane, and MAIN receives only its merge handback"
}

test_away_explicit_decision_trigger_is_lane_local() {
  local home state terminal out
  for terminal in progress "done" failed merged teardown; do
    home=$(make_home "handback-decision-local-$terminal" away)
    state="$home/state"
    printf 'turn=h1\nrows=1 2\ntasks=demo other\nunscoped=1\nwake=signal: other.status\nposture=away\ncheck=check: review finding for demo\n' > "$state/.supervision-host-turn"
    case "$terminal" in
      done|failed) printf 'event=demo\t%s: lane stopped\n' "$terminal" >> "$state/.supervision-host-turn" ;;
      merged) printf 'check=check: merge landed: demo https://example.test/o/r/pull/1\nmerged-task=demo\n' >> "$state/.supervision-host-turn" ;;
      teardown) rm "$state/demo.meta" ;;
    esac
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
      --task demo --verdict captain --main-action decision --summary 'review finding needs input' 2>&1) \
      || fail "$terminal: explicit decision report failed: $out"
    assert_grep 'decision for demo (outcome 1), event decision:' "$state/.wake-queue" "$terminal: explicit decision must keep a lane-local label"
    assert_no_grep 'other.status' "$state/.wake-queue" "$terminal: explicit decision must not inherit a sibling wake"
    [ "$(awk -F '\t' '$5 == "decision" { n++ } END { print n+0 }' "$state/.supervision-host-receipts")" = 1 ] \
      || fail "$terminal: explicit decision changed its action"
  done
  home=$(make_home handback-decision-local-batch away)
  state="$home/state"
  echo handback-check > "$home/stub-mode"
  echo decision > "$home/stub-main-action"
  printf 'project=other\nwindow=fm-other\nharness=claude\n' > "$state/other.meta"
  printf 'working: other lane is running\n' > "$state/other.status"
  prime_status_seen "$state" "$state/other.status"
  append_wake "$state" signal other.status "signal: $state/other.status"
  append_wake "$state" check review 'check: review finding for demo'
  start_host "$home"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "explicit decision left MAIN parked"
  assert_grep 'other.status' "$home/engine-drain.1" "the sibling signal must be presented to the engine"
  assert_grep 'check: review finding for demo' "$home/engine-drain.1" "the decision check must be presented to the engine"
  assert_grep 'decision for demo (outcome 1), event decision:' "$home/host.out" "the host must name the lane-local decision"
  assert_no_grep 'other.status' "$home/host.out" "the host must not pass the handled sibling to MAIN"
  main_drain_and_ack "$home"
  assert_grep 'decision for demo (outcome 1), event decision:' "$home/main-drain.out" "MAIN must receive the lane-local decision"
  assert_no_grep 'other.status' "$home/main-drain.out" "MAIN must not repeat the handled sibling"
  stop_home_processes "$home"
  pass "away explicit decisions: sibling wakes and terminal events cannot relabel a lane's input handback"
}

test_away_derived_dispatch_is_once_per_turn_and_task() {
  local home state trigger action out rows
  for trigger in "done" failed merged teardown; do
    home=$(make_home "handback-dedup-$trigger" away)
    state="$home/state"
    printf 'turn=h1\nrows=1\ntasks=demo other\nunscoped=0\nwake=signal: demo.status other.status\nposture=away\n' > "$state/.supervision-host-turn"
    case "$trigger" in
      done) printf 'event=demo\tdone: ready branch\nevent=other\tdone: other ready branch\n' >> "$state/.supervision-host-turn" ;;
      failed) printf 'event=demo\tfailed: build broke\nevent=other\tfailed: other build broke\n' >> "$state/.supervision-host-turn" ;;
      merged) printf 'turn=h1\nrows=1\ntasks=demo other\nunscoped=1\nwake=check: merge landed: demo https://example.test/o/r/pull/1\nposture=away\ncheck=check: merge landed: demo https://example.test/o/r/pull/1\nmerged-task=demo\n' > "$state/.supervision-host-turn" ;;
      teardown) rm "$state/demo.meta" ;;
    esac
    for action in auto auto captain-hold captain-hold decision; do
      out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
        --task demo --verdict captain --main-action "$action" --summary "handled $action" 2>&1) \
        || fail "$trigger/$action: report failed: $out"
    done
    rows=$(cat "$state/.wake-queue")
    [ "$(awk -F '\t' '$5 ~ /handback: dispatch for demo / { n++ } END { print n+0 }' "$state/.wake-queue")" = 1 ] \
      || fail "$trigger: repeated reports queued duplicate derived dispatch: $rows"
    assert_contains "$rows" 'handback: decision for demo (outcome 5)' "$trigger: explicit decision must survive terminal detection and deduplication"
    [ "$(awk -F '\t' '$5 == "dispatch" { n++ } END { print n+0 }' "$state/.supervision-host-receipts")" = 1 ] \
      || fail "$trigger: duplicate derived dispatch receipt remained"
    [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list | wc -l | tr -d ' ')" = 5 ] \
      || fail "$trigger: deduplication lost handled-event outcomes"
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
      --task demo --verdict routine --main-action dispatch --summary 'new explicit cleanup work' 2>&1) \
      || fail "$trigger: explicit dispatch report failed: $out"
    assert_grep 'handback: dispatch for demo (outcome 6)' "$state/.wake-queue" "$trigger: derived deduplication must not suppress explicit dispatch"
    if [ "$trigger" = "done" ] || [ "$trigger" = failed ]; then
      out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h1 "$REPORT" \
        --task other --verdict routine --summary 'other lane finished' 2>&1) \
        || fail "another lane's report failed: $out"
      assert_grep 'handback: dispatch for other (outcome 7)' "$state/.wake-queue" "deduplication must be task scoped"
    fi
    sed 's/^turn=h1$/turn=h2/' "$state/.supervision-host-turn" > "$state/next-turn"
    mv "$state/next-turn" "$state/.supervision-host-turn"
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=h2 "$REPORT" \
      --task demo --verdict routine --summary 'new turn terminal event' 2>&1) \
      || fail "$trigger: new turn report failed: $out"
    [ "$(awk -F '\t' '$1 == "h2" && $4 == "demo" && $5 == "dispatch" { n++ } END { print n+0 }' "$state/.supervision-host-receipts")" = 1 ] \
      || fail "$trigger: deduplication must be turn scoped"
  done
  pass "away dispatch handback: derived terminal reports collapse per turn and task while explicit actions and outcomes survive"
}

test_away_handback_survives_ack_and_resumes_host_after_main() {
  local home watcher out calls
  home=$(make_home away-handback-cycle away)
  start_session "$home"
  park_again "$home"
  wait_until 150 watcher_live "$home" || fail "handback: watcher never started"
  append_status "$home" 'worker ready' 'done'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "handback: done worker left MAIN parked"
  assert_grep 'away handback: check: supervision-host handback: dispatch for demo (outcome 1), event done:' "$home/host.out" "terminal wake needs a clear reason"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the original signal should be acknowledged"
  assert_grep 'supervision-host-handback:' "$home/state/.wake-queue" "MAIN's action must survive acknowledgement"
  [ "$(marker_kind "$home")" = downtime ] || fail "MAIN handback must restore downtime"
  watcher_live "$home" && fail "handback left a competing watcher"
  [ "$(FM_HOME="$home" "$CONTRACT" mode)" = away ] || fail "handback archived away posture"
  calls=$(engine_calls "$home")
  # Simulate an owner that dropped the first close: the next park must pass
  # the durable handback to MAIN, rather than let another engine consume it.
  park_again "$home"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "handback: next park swallowed the pending MAIN action"
  [ "$(engine_calls "$home")" = "$calls" ] || fail "handback was offered to another engine"
  main_drain_and_ack "$home"
  park_again "$home"
  wait_until 150 watcher_live "$home" || fail "handback: resumed watcher never started"
  calls=$(handled_count "$home")
  append_wake "$home/state" check validation 'check: validation still running for demo'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" "$((calls + 1))" || fail "handback: later check was not handled"
  host_exited "$home" && fail "handback: old done status woke MAIN on a later check"
  assert_no_grep 'supervision-host-handback:' "$home/state/.wake-queue" "old done status must not queue another handback"
  append_status "$home" 'next worker running'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" "$((calls + 2))" || fail "handback: host did not resume after MAIN acknowledged: $(cat "$home/host.out" "$home/main-drain.out" "$home/state/.wake-queue" "$home/state/.supervision-host.log" 2>/dev/null)"
  host_exited "$home" && fail "handback: routine successor woke MAIN"
  watcher=$(cat "$home/state/.watch.lock/pid")
  stop_home_processes "$home"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "handback: watcher not stopped"
  pass "away handback: MAIN work survives engine acknowledgement and a dropped close, then the same posture resumes routine supervision"
}

test_away_worker_input_handback_and_captain_hold() {
  local home verb
  for verb in needs-decision blocked; do
    home=$(make_home "away-input-handback-$verb" away)
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "input: watcher never started"
    append_status "$home" 'firstmate input needed' "$verb [key=input-1]"
    # The fork's slower CI runners need headroom for this host/engine wait.
    wait_until 450 host_exited "$home" || fail "input: unanswered $verb left MAIN parked"
    assert_grep "away handback: check: supervision-host handback: decision for demo (outcome 1), event $verb [key=input-1]:" "$home/host.out" "input wake must name its decision key"
    assert_grep 'supervision-host-handback:' "$home/state/.wake-queue" "input wake must stay durable"
    stop_home_processes "$home"
  done

  home=$(make_home away-captain-hold away)
  echo captain-hold > "$home/stub-main-action"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hold: watcher never started"
  append_status "$home" 'requires the captain' needs-decision
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 1 || fail "hold: engine did not handle the event"
  host_exited "$home" && fail "hold: genuine captain call woke MAIN"
  assert_no_grep 'supervision-host-handback:' "$home/state/.wake-queue" "hold must wait for return"
  rm "$home/stub-main-action"
  append_status "$home" 'routine work continues'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 handled_at_least "$home" 2 || fail "hold: later routine event was not handled"
  host_exited "$home" && fail "hold: standing decision woke MAIN on a later signal"
  assert_no_grep 'supervision-host-handback:' "$home/state/.wake-queue" "standing decision must not repeat its handback"
  stop_home_processes "$home"
  pass "away worker input reaches MAIN, while explicit captain-owned holds stay for return"
}

test_away_handback_drains_only_the_handed_lane() {
  local home out verb
  for verb in "done" failed; do
    home=$(make_home "away-handback-batch-$verb" away)
    echo handback-batch > "$home/stub-mode"
    printf 'project=other\nwindow=fm-other\nharness=claude\n' > "$home/state/other.meta"
    printf 'working: continuing\n' > "$home/state/other.status"
    printf '%s: lane stopped\n' "$verb" > "$home/state/demo.status"
    printf 'working: validation running\n' >> "$home/state/demo.status"
    # Publish the status presentation once, as the watcher does, before seeding
    # its two rows; otherwise startup also discovers duplicate fixture signals.
    prime_status_seen "$home/state" "$home/state/demo.status"
    prime_status_seen "$home/state" "$home/state/other.status"
    append_wake "$home/state" signal demo.status "signal: $home/state/demo.status"
    append_wake "$home/state" signal other.status "signal: $home/state/other.status"
    start_host "$home"
    # The fork's slower CI runners need headroom for this host/engine wait.
    wait_until 450 host_exited "$home" || fail "batch: host did not hand back the lane"
    assert_grep 'other.status' "$home/engine-drain.1" "batch fixture must present both lanes to the engine"
    assert_grep 'demo.status' "$home/engine-drain.1" "batch fixture must present the handed lane to the engine"
    assert_grep "away handback: check: supervision-host handback: dispatch for demo (outcome 1), event $verb:" "$home/host.out" "handback must name lane and event"
    assert_no_grep 'other.status' "$home/host.out" "handled lane must not cost MAIN close context"
    out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "batch: main drain failed: $out"
    assert_contains "$out" 'check: supervision-host handback: dispatch for demo' "MAIN must see the handed lane"
    assert_not_contains "$out" 'other.status' "MAIN must not re-read the handled lane"
    assert_not_contains "$out" 'signal:' "MAIN must not re-read original acknowledged signals"
    [ "$(awk -F '\t' 'NF >= 5 { n++ } END { print n+0 }' "$home/state/.wake-queue")" = 1 ] \
      || fail "batch: MAIN queue contains rows beyond the handed lane"
    main_drain_and_ack "$home"
    stop_home_processes "$home"
  done
  pass "away handback: the engine acknowledges other handled lanes first; MAIN drains only the named handback lane"
}

test_away_multiple_handbacks_keep_one_complete_reason_line() {
  local home reason first_reason calls rows
  home=$(make_home handback-multiple away)
  echo handback-multiple > "$home/stub-mode"
  printf 'project=other\nwindow=fm-other\nharness=claude\n' > "$home/state/other.meta"
  printf 'done: demo ready\n' > "$home/state/demo.status"
  printf 'done: other ready\n' > "$home/state/other.status"
  prime_status_seen "$home/state" "$home/state/demo.status"
  prime_status_seen "$home/state" "$home/state/other.status"
  append_wake "$home/state" signal demo.status "signal: $home/state/demo.status"
  append_wake "$home/state" signal other.status "signal: $home/state/other.status"
  start_session "$home"
  park_again "$home"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "multiple: host did not hand back both lanes"
  reason=$(sed -n '/^supervision-host: away handback:/p' "$home/host.out")
  first_reason=$reason
  assert_contains "$reason" 'dispatch for demo (outcome 1), event done: stub handled demo' "reason must name demo's event"
  assert_contains "$reason" 'dispatch for other (outcome 2), event done: other worker remains busy; nothing new; no action taken' "reason must name the other lane's event"
  assert_contains "$reason" 'decision for demo (outcome 4), event decision: firstmate input still needed' "terminal events must not relabel an explicit decision"
  [ "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" = 1 ] || fail "multiple: handback reason spans lines"
  assert_no_grep 'signal:' "$home/state/.wake-queue" "all originally granted rows must be acknowledged"
  rows=$(awk -F '\t' '$4 ~ /^supervision-host-handback:/ { n++ } END { print n+0 }' "$home/state/.wake-queue")
  [ "$rows" = 3 ] || fail "multiple: expected two lane dispatches and one explicit decision, got $rows"
  calls=$(engine_calls "$home")
  park_again "$home"
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "multiple: pending handbacks were swallowed"
  [ "$(engine_calls "$home")" = "$calls" ] || fail "multiple: another engine received the pending handbacks"
  reason=$(sed -n '/^supervision-host: away handback:/p' "$home/host.out")
  [ "$reason" = "$first_reason" ] || fail "pending and post-turn handbacks must have identical reasons"
  assert_contains "$reason" 'dispatch for demo (outcome 1)' "pending reason lost demo dispatch"
  assert_contains "$reason" 'dispatch for other (outcome 2)' "pending reason lost other dispatch"
  assert_contains "$reason" 'decision for demo (outcome 4)' "pending reason lost explicit decision"
  [ "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" = 1 ] || fail "pending handback reason spans lines"
  main_drain_and_ack "$home"
  assert_grep 'dispatch for other (outcome 2)' "$home/main-drain.out" "MAIN must receive the second handed lane"
  [ "$(FM_HOME="$home" "$CONTRACT" mode)" = away ] || fail "multiple: away record changed"
  stop_home_processes "$home"
  pass "away handback: receipt and pending-row paths preserve all lanes and actions in one reason line"
}

test_herdr_endpoint_bindings_follow_crew_state_metadata() {
  local home state endpoint out rc
  home="$TMP_ROOT/herdr-bindings"
  state="$home/state"
  mkdir -p "$state"
  for endpoint in default:w1F:p2 default:w1J:p2 fm-Mosaiq:w8D:p2; do
    # The old field deliberately diverges from the current one, as after a
    # metadata update. crew-state's owner reads the last value, not the first.
    printf 'project=demo\nbackend=herdr\nwindow=old:w0:p1\nwindow=%s\n' "$endpoint" > "$state/demo.meta"
    : > "$state/.wake-queue"
    append_wake "$state" stale "$endpoint" "stale: $endpoint"
    out=$(FM_HOME="$home" node "$DISPATCH" scope --afk) || fail "Herdr scope failed"
    assert_contains "$out" 'status=safe' "the current recorded endpoint must be claimable"
    assert_contains "$out" 'tasks=demo' "the endpoint must map to its task"
    out=$(printf 'stale: %s\n' "$endpoint" | FM_HOME="$home" node "$DISPATCH" offer --afk)
    assert_contains "$out" 'eligible=1' "the away host must accept the mapped endpoint"
    out=$(printf 'stale: %s\n' "$endpoint" | FM_HOME="$home" node "$DISPATCH" wake-prompt --report report)
    assert_contains "$out" "\"endpoint\":\"$endpoint\",\"task\":\"demo\"" "the engine must receive the task binding"
    # Exercise the exact public shell owner crew-state calls, with no live
    # Herdr inspection or lifecycle operation.
    out=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_target_of_meta "$2"' _ "$ROOT" "$state/demo.meta")
    [ "$out" = "$endpoint" ] || fail "host and crew-state target owner disagree"
  done

  # Prefixes and old pane identities never alias the currently recorded pane.
  for endpoint in Mosaiq:w8D:p2 old:w0:p1; do
    : > "$state/.wake-queue"
    append_wake "$state" stale "$endpoint" "stale: $endpoint"
    out=$(FM_HOME="$home" node "$DISPATCH" scope --afk 2>&1)
    assert_contains "$out" 'corrupted=1' "a nonmatching endpoint must fail closed"
    assert_contains "$out" "\"endpoint\":\"$endpoint\"" "a lookup miss must log its exact address"
    assert_contains "$out" '"window":"fm-Mosaiq:w8D:p2"' "a miss must log the compared window"
    assert_contains "$out" '"terminal":""' "a miss must log the compared terminal"
    assert_contains "$out" "\"state\":\"$state\"" "a miss must identify the scanned home"
  done

  # Orca's terminal is the target owner even when a legacy window is present.
  printf 'project=demo\nbackend=orca\nwindow=legacy\nterminal=orca:term-1\n' > "$state/demo.meta"
  : > "$state/.wake-queue"
  append_wake "$state" stale orca:term-1 'stale: orca:term-1'
  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk)
  assert_contains "$out" 'tasks=demo' "Orca must use crew-state's terminal selection"

  # Two records claiming one endpoint cannot authorize a guessed task.
  cp "$state/demo.meta" "$state/other.meta"
  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk 2>&1)
  assert_contains "$out" 'corrupted=1' "duplicate endpoint ownership must fail closed"
  assert_contains "$out" '"task":"other"' "the diagnostic must include every conflicting record"
  out=$(printf 'stale: orca:term-1\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report report 2>&1)
  assert_contains "$out" 'endpoint lookup miss' "an ambiguous prompt must report unproven ownership"
  rm "$state/other.meta"

  # NUL framing preserves empty fields, equals signs, and spaces in paths.
  printf 'project=demo=fixture\nkind=secondmate\nbackend=zellij\nwindow=lab:tab:pane\n' > "$state/demo.meta"
  out=$(bash "$ROOT/bin/fm-endpoint-records.sh" "$state" | python3 -c 'import sys; f=sys.stdin.buffer.read().split(b"\0"); assert len(f)==9 and f[-1]==b""; assert f[2]==b"demo=fixture" and f[6]==b""; print(f[7].decode())')
  [ "$out" = 'lab:tab:pane' ] || fail "endpoint snapshot lost field framing"
  rc=0
  bash "$ROOT/bin/fm-endpoint-records.sh" "$state/absent" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an absent state directory must refuse the snapshot"
  pass "Herdr endpoint bindings use crew-state's target owner, preserve exact identities, and diagnose misses"
}

test_dispatch_endpoint_diagnostics_respect_caller_sink() {
  local state out rc
  state="$TMP_ROOT/endpoint-diagnostics/state"
  mkdir -p "$state"
  STATE="$state" LIB="$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" DISPATCH="$DISPATCH" \
    node --input-type=module > "$TMP_ROOT/endpoint-diagnostics.out" 2> "$TMP_ROOT/endpoint-diagnostics.err" <<'JS'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { rmSync, symlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { branchOfferForWake, branchWakePrompt, scopeForUnreadWake } = await import(pathToFileURL(process.env.LIB).href);
const state = process.env.STATE;
const endpoint = "fm-Mosaiq:w8D:p2";
const message = `stale: ${endpoint}`;
const record = `project=demo\nbackend=herdr\nwindow=${endpoint}\n`;
const consoleCalls = [];
for (const method of ["error", "warn", "log", "info", "debug"]) {
  console[method] = (...args) => consoleCalls.push([method, ...args]);
}
writeFileSync(`${state}/.wake-queue`, `1\t1\tstale\t${endpoint}\t${message}\n`);

function host(command, args = []) {
  const result = spawnSync(process.execPath, ["--disable-warning=MODULE_TYPELESS_PACKAGE_JSON", process.env.DISPATCH, command, ...args], {
    encoding: "utf8",
    input: `${message}\n`,
    env: { ...process.env, FM_STATE_OVERRIDE: state },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.stderr.includes("MODULE_TYPELESS_PACKAGE_JSON"), result.stderr);
  return result;
}

function rejectedCalls(expectedPromptDetail) {
  for (const afk of [false, true]) {
    const scope = scopeForUnreadWake(state, false, afk);
    assert.equal(scope.corrupted, true);
    assert.deepEqual(scope.eligibleTasks, []);
    const offer = branchOfferForWake(state, message, afk);
    assert.equal(offer.eligible, false);
    assert.deepEqual(offer.scope.eligibleSeqs, []);
  }
  const prompt = branchWakePrompt(message, "fm_branch_report", "", "", state);
  assert.ok(prompt.includes(expectedPromptDetail), prompt);
  assert.ok(!prompt.includes(`"endpoint":"${endpoint}","task":`), prompt);
  return prompt;
}

function misses() {
  const prompt = rejectedCalls("endpoint lookup miss:");
  assert.ok(prompt.includes('"compared":'), prompt);
  const diagnostics = [];
  const sink = (detail) => diagnostics.push(detail);
  scopeForUnreadWake(state, false, false, false, sink);
  assert.equal(diagnostics.length, 1);
  branchOfferForWake(state, message, false, false, sink);
  assert.equal(diagnostics.length, 2);
  branchOfferForWake(state, message, true, false, sink);
  assert.equal(diagnostics.length, 4);
  assert.equal(branchWakePrompt(message, "fm_branch_report", "", "", state, sink), prompt);
  assert.equal(diagnostics.length, 5);
  for (const detail of diagnostics) {
    const data = JSON.parse(detail.slice("endpoint lookup miss: ".length));
    assert.equal(data.state, state);
    assert.equal(data.endpoint, endpoint);
    assert.ok(Array.isArray(data.compared));
  }
  for (const [command, args] of [["scope", ["--afk"]], ["offer", ["--afk"]], ["wake-prompt", ["--report", "report"]]]) {
    const result = host(command, args);
    assert.ok(result.stderr.includes(diagnostics[0]), result.stderr);
    if (command === "wake-prompt") assert.ok(result.stdout.includes(diagnostics[0]), result.stdout);
    else {
      assert.ok(!result.stdout.includes("endpoint lookup"), result.stdout);
      assert.ok(result.stdout.includes("corrupted=1"), result.stdout);
      if (command === "offer") assert.ok(result.stdout.includes("eligible=0"), result.stdout);
    }
  }
}

misses();
writeFileSync(`${state}/demo.meta`, record);
writeFileSync(`${state}/other.meta`, record);
misses();
rmSync(`${state}/other.meta`);
for (const afk of [false, true]) {
  assert.deepEqual(scopeForUnreadWake(state, false, afk).eligibleTasks, ["demo"]);
  assert.equal(branchOfferForWake(state, message, afk).eligible, true);
}
assert.ok(branchWakePrompt(message, "fm_branch_report", "", "", state).includes(`"endpoint":"${endpoint}","task":"demo"`));
for (const [command, args] of [["scope", ["--afk"]], ["offer", ["--afk"]], ["wake-prompt", ["--report", "report"]]]) {
  const result = host(command, args);
  assert.ok(!/endpoint lookup (?:miss|unavailable):|unreadable endpoint metadata:/.test(result.stderr), result.stderr);
  assert.ok(result.stdout.includes(command === "wake-prompt" ? '"task":"demo"' : "tasks=demo"), result.stdout);
}

symlinkSync(`${state}/absent`, `${state}/broken.meta`);
const unavailablePrompt = rejectedCalls("endpoint lookup unavailable:");
assert.ok(unavailablePrompt.includes("Endpoint ownership is unproven"), unavailablePrompt);
const diagnostics = [];
assert.equal(branchWakePrompt(message, "fm_branch_report", "", "", state, (detail) => diagnostics.push(detail)), unavailablePrompt);
assert.equal(diagnostics.length, 1);
assert.ok(diagnostics[0].includes("unreadable endpoint metadata"), diagnostics[0]);
for (const [command, args] of [["scope", ["--afk"]], ["offer", ["--afk"]], ["wake-prompt", ["--report", "report"]]]) {
  const unavailable = host(command, args);
  assert.ok(unavailable.stderr.includes("endpoint lookup unavailable:"), unavailable.stderr);
  assert.ok(unavailable.stderr.includes("unreadable endpoint metadata"), unavailable.stderr);
  if (command === "wake-prompt") assert.ok(unavailable.stdout.includes(diagnostics[0]), unavailable.stdout);
  else assert.ok(unavailable.stdout.includes("corrupted=1"), unavailable.stdout);
}
assert.deepEqual(consoleCalls, []);
JS
  rc=$?
  out=$(cat "$TMP_ROOT/endpoint-diagnostics.out" "$TMP_ROOT/endpoint-diagnostics.err")
  expect_code 0 "$rc" "endpoint diagnostic routing must preserve silent Pi calls and host stderr: $out"
  assert_no_re 'endpoint lookup (miss|unavailable):|unreadable endpoint metadata:' "$TMP_ROOT/endpoint-diagnostics.err" "shared endpoint calls leaked diagnostics: $out"
  pass "dispatch diagnostics use the caller sink, keep Pi silent, and preserve host output and ownership checks"
}

test_quiet_words_reach_the_engine_and_report_now() {
  local home drained
  home=$(make_home quiet-words attended)
  FM_HOME="$home" FM_AFK_MODE=quiet "$CONTRACT" enter --words 'merge green PRs for devops and github' >/dev/null \
    || fail "fixture: quiet words could not be recorded"
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet words: no watcher"
  append_status "$home" 'ready for review'
  # The fork's slower CI runners need headroom for this host/engine wait.
  wait_until 450 host_exited "$home" || fail "quiet words: outcome never reached the present captain"
  assert_re '^POSTURE: QUIET\.' "$home/engine-call.1" "quiet wake must identify the present captain"
  assert_contains "$(cat "$home/engine-call.1")" 'merge green PRs for devops and github' "quiet wake must carry the exact recorded words"
  assert_contains "$(cat "$home/engine-call.1")" 'per your quiet instructions:' "quiet wake must require immediate attributed reporting"
  assert_no_re '^POSTURE: AWAY' "$home/engine-call.1" "quiet wake must not park main"
  assert_re 'MAIN DIALOG MIRROR' "$home/engine-call.1" "quiet wake must retain the present captain's dialog"
  assert_re '	handled	turn=[^	]*	posture=quiet	' "$home/state/.supervision-host.log" "the ledger must record the quiet turn"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "a quiet captain report must use the present-captain path"
  assert_no_grep 'the captain has returned' "$home/engine-report.log" "a quiet report must never claim the captain returned"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "a quiet report must queue no captain-returned relay"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" 'BRANCH OUTCOMES' "quiet outcome must be available now"
  assert_not_contains "$drained" 'was recorded after the captain returned' "the drain must carry no captain-returned relay for a quiet outcome"
  pass "quiet words reach the generated wake interface with present-captain reporting and immediate outcomes"
}

test_routine_unsticking_closes_each_stop_without_main_handback() {
  local home shape out
  for shape in no-run optional-probe replaced-target cancelled-custody; do
    home=$(make_home "unstick-$shape" away)
    echo routine-unstick > "$home/stub-mode"
    case "$shape" in
      no-run) echo 'AXI has no active run and daemon is healthy; foreground drive validation' > "$home/remedy" ;;
      optional-probe) echo 'accepted ruling excludes browser probe; skip it and record configuration read' > "$home/remedy" ;;
      replaced-target) echo 'pipeline roll replaced old replica; read live revision and retry authorized exec' > "$home/remedy" ;;
      cancelled-custody) echo 'cancelled run, clean copy, all changes preserved and pushed head equals required head; reset own branch to verified head' > "$home/remedy" ;;
    esac
    FM_HOME="$home" "$CONTRACT" enter --words 'unstuck workers; merge nothing' >/dev/null 2>&1 || fail 'could not record unsticking words'
    # Durable enqueue is the real send interface. A failing doorbell cannot
    # undo delivery; the watcher remains on the fixture's unreachable tmux.
    start_host "$home"
    wait_until 450 watcher_live "$home" || fail "$shape watcher not live: $(cat "$home/host.out" "$home/claude.err" "$home/state/.supervision-host.log" 2>/dev/null)"
    append_status "$home" "$shape needs routine remedy" 'blocked [key=routine-stop]'
    # The fork's slower CI runners need headroom for this host/engine wait.
    wait_until 450 handled_at_least "$home" 1 || fail "$shape was not handled: $(cat "$home/engine-steer.log" 2>/dev/null)"
    [ ! -s "$home/host.rc" ] || fail "$shape handed back to main"
    # The final prompt sent to the engine is an owned generated interface;
    # pin the evidence instruction separately from the scripted decisions.
    case "$shape" in
      no-run) assert_grep 'verify no active run owns the branch' "$home/engine-prompt.1" 'no-run evidence absent from emitted prompt' ;;
      optional-probe) assert_grep 'verify the probe is outside the required evidence' "$home/engine-prompt.1" 'probe evidence absent from emitted prompt' ;;
      replaced-target) assert_grep 'verify the old target disappeared because of that roll' "$home/engine-prompt.1" 'revision evidence absent from emitted prompt' ;;
      cancelled-custody) assert_grep 'live pushed head equals the observed required head' "$home/engine-prompt.1" 'custody evidence absent from emitted prompt' ;;
    esac
    assert_grep 'never pass `--main-action dispatch` or `decision` for it' "$home/engine-prompt.1" 'routine report action absent from emitted prompt'
    assert_grep "$(cat "$home/remedy")" "$home/state/demo.inbox/001.msg" "$shape remedy was not delivered"
    out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
    assert_not_contains "$out" 'OPEN DECISIONS' "$shape blocker remained open"
    assert_no_grep 'supervision-host-handback:' "$home/state/.wake-queue" "$shape queued a handback"
    assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "$shape escalated routine recovery"
    assert_grep '"silent":false' "$home/state/branch-outcomes.jsonl" "$shape hid the recovery note"
    stop_home_processes "$home"
  done
  pass 'routine unsticking: four remedies deliver and close blockers without MAIN handback'
}

test_merged_sweep_skips_already_closed_tasks() {
  local home state kind out rc expected_task check_task
  for kind in missing active builtin; do
    home=$(make_home "closed-sweep-$kind" away)
    state="$home/state"
    echo merged-sweep > "$home/stub-mode"
    printf 'pr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397\n' >> "$state/demo.meta"
    printf 'project=demo\npr=https://dev.azure.com/acme/project/_git/Other.Repository/pullrequest/59397\n' > "$state/ado-pr-sweep.meta"
    if [ "$kind" != active ]; then
      rm "$state/demo.meta"
    fi
    start_host "$home"
    wait_until 450 watcher_live "$home" || fail "sweep watcher not live: $(cat "$home/host.out" "$home/claude.err" "$home/state/.supervision-host.log" 2>/dev/null)"
    expected_task=fleet
    if [ "$kind" = builtin ]; then
      expected_task=demo
      append_wake "$state" check merged-demo 'check: merge landed: demo https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397'
    else
      append_wake "$state" check ado-pr-sweep "check: $state/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59397 MERGED (Mosaiq.Codegraph) - task pull request"
    fi
    if [ "$kind" = active ]; then
      # The fork's slower CI runners need headroom for this host/engine wait.
      wait_until 450 host_exited "$home" || fail 'actual cleanup did not hand back freed slot'
      [ -e "$home/teardown-attempted" ] || fail 'active task cleanup was skipped'
      assert_grep 'handback: dispatch for demo' "$home/host.out" 'actual cleanup lost dispatch handback'
      assert_grep 'merged-task=demo' "$home/engine-call.1" 'owning task resolution was not delivered to the engine'
    else
      # The fork's slower CI runners need headroom for this host/engine wait.
      wait_until 450 handled_at_least "$home" 1 || fail "closed sweep not handled: $(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -e "$home/teardown-attempted" ] || fail 'already closed task attempted teardown'
      [ ! -s "$home/host.rc" ] || fail 'duplicate sweep handed back'
      assert_grep '"verdict":"routine"' "$state/branch-outcomes.jsonl" 'closed sweep became captain outcome'
      assert_grep "\"task\":\"$expected_task\"" "$state/branch-outcomes.jsonl" 'sweep used a check name or an unrelated task as its owner'
      assert_grep "closed-task=$expected_task" "$home/engine-call.1" 'closed resolution was not delivered to the engine'
      assert_no_grep 'supervision-host-handback:' "$state/.wake-queue" 'closed sweep queued a handback'
    fi
    stop_home_processes "$home"
  done
  # The report flag cannot hide live records, missing pre-turn proof, foreign
  # checks, or a captain outcome. It writes nothing on refusal.
  home=$(make_home closed-sweep-guard away)
  state="$home/state"
  for kind in active no-snapshot foreign captain silent; do
    check_task=demo
    [ "$kind" != foreign ] || check_task=other
    printf 'turn=t1\nrows=1\ntasks=demo\nunscoped=0\nposture=away\ncheck=check: merge landed: %s https://example.test/o/r/pull/1\nmerged-task=%s\n' "$check_task" "$check_task" > "$state/.supervision-host-turn"
    [ "$kind" = no-snapshot ] || printf 'closed-task=demo\n' >> "$state/.supervision-host-turn"
    [ "$kind" = active ] || rm -f "$state/demo.meta"
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task demo --verdict "$([ "$kind" = captain ] && echo captain || echo routine)" --main-action already-closed --summary skipped --silent "$([ "$kind" = silent ] && echo true || echo false)" 2>&1); rc=$?
    expect_code 3 "$rc" "$kind must refuse closed-task suppression"
    [ ! -e "$state/branch-outcomes.jsonl" ] || fail 'refused suppression wrote an outcome'
  done
  for kind in owner different-pr different-repo different-provider duplicate-pr; do
    home=$(make_home "custom-sweep-owner-$kind" away)
    state="$home/state"
    printf 'pr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397\n' >> "$state/demo.meta"
    case "$kind" in
      different-pr) sed 's/59397/59398/' "$state/demo.meta" > "$home/meta"; mv "$home/meta" "$state/demo.meta" ;;
      different-repo) sed 's/Mosaiq.Codegraph/Other.Repository/' "$state/demo.meta" > "$home/meta"; mv "$home/meta" "$state/demo.meta" ;;
      different-provider) sed 's|https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397|https://github.com/acme/Mosaiq.Codegraph/pull/59397|' "$state/demo.meta" > "$home/meta"; mv "$home/meta" "$state/demo.meta" ;;
      duplicate-pr) printf 'pr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397\n' >> "$state/demo.meta" ;;
    esac
    printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nposture=away\ncheck=check: %s/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59397 MERGED (Mosaiq.Codegraph) - task pull request\n' "$state" > "$state/.supervision-host-turn"
    out=$(bash -c '. "$1"; fm_pr_merged_check_tasks "$2" "$3"' _ "$ROOT/bin/fm-pr-lib.sh" "$state" "$state/.supervision-host-turn") \
      || fail "$kind snapshot resolution failed"
    printf '%s\n' "$out" | sed 's/^/merged-task=/' >> "$state/.supervision-host-turn"
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task demo --verdict routine --summary handled 2>&1) \
      || fail "$kind report failed: $out"
    case "$kind" in
      owner|duplicate-pr) assert_grep 'handback: dispatch for demo' "$state/.wake-queue" "$kind lost the owning lane's handback" ;;
      *) out=$(cat "$state/.wake-queue" 2>/dev/null || true); assert_not_contains "$out" 'supervision-host-handback:' "$kind handed back an unrelated lane" ;;
    esac
  done
  for kind in new-owner ambiguous-owner check-name no-snapshot foreign; do
    home=$(make_home "custom-sweep-guard-$kind" away)
    state="$home/state"
    rm "$state/demo.meta"
    expected_task=fleet
    printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nposture=away\ncheck=check: %s/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59397 MERGED (Mosaiq.Codegraph) - task pull request\nmerged-task=fleet\nclosed-task=fleet\n' "$state" > "$state/.supervision-host-turn"
    case "$kind" in
      new-owner|ambiguous-owner)
        printf 'pr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397\n' > "$state/demo.meta"
        [ "$kind" != ambiguous-owner ] || cp "$state/demo.meta" "$state/other.meta"
        ;;
      check-name) expected_task=ado-pr-sweep; printf 'closed-task=ado-pr-sweep\n' >> "$state/.supervision-host-turn" ;;
      no-snapshot) sed '/^closed-task=/d' "$state/.supervision-host-turn" > "$home/turn"; mv "$home/turn" "$state/.supervision-host-turn" ;;
      foreign) sed 's/ MERGED / ACTIVE /' "$state/.supervision-host-turn" > "$home/turn"; mv "$home/turn" "$state/.supervision-host-turn" ;;
    esac
    out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task "$expected_task" --verdict routine --main-action already-closed --summary skipped 2>&1); rc=$?
    expect_code 3 "$rc" "$kind must refuse custom sweep suppression"
    [ ! -e "$state/branch-outcomes.jsonl" ] || fail 'refused custom suppression wrote an outcome'
    [ ! -e "$state/.supervision-host-receipts" ] || fail 'refused custom suppression wrote a receipt'
    [ ! -e "$state/.wake-queue" ] || fail 'refused custom suppression queued a handback'
    if [ "$kind" = new-owner ]; then
      out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task demo --verdict routine --summary 'task appeared after turn start' 2>&1); rc=$?
      expect_code 0 "$rc" 'a new owner may report a routine outcome'
      [ ! -e "$state/.wake-queue" ] || fail 'report-time ownership triggered a merge handback absent from the snapshot'
    fi
  done
  pass 'merged sweep: absent owners skip teardown, active cleanup hands back, and new owners cannot trigger merge dispatch'
}

test_merged_sweep_handles_every_report_in_a_row() {
  local home state kind payload tasks out
  for kind in missing mixed; do
    home=$(make_home "sweep-multiple-$kind" away)
    state="$home/state"
    echo merged-sweep > "$home/stub-mode"
    payload="check: $state/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59396 MERGED (Mosaiq.Codegraph) - first closed PR
ado-pr-sweep: PR 59399 MERGED (Mosaiq.Codegraph) - last closed PR"
    if [ "$kind" = mixed ]; then
      printf 'pr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397\n' >> "$state/demo.meta"
      printf 'project=demo\npr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59398\n' > "$state/other.meta"
      payload="check: $state/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59390 has MERGE CONFLICTS (Mosaiq.X) - conflicts
ado-pr-sweep: PR 59391 ABANDONED (Mosaiq.Codegraph) - abandoned
ado-pr-sweep: PR 59396 MERGED (Mosaiq.Codegraph) - first closed PR
ado-pr-sweep: PR 59397 MERGED (Mosaiq.Codegraph) - first live PR
ado-pr-sweep: PR 59398 MERGED (Mosaiq.Codegraph) - second live PR
ado-pr-sweep: PR 59399 MERGED (Mosaiq.Codegraph) - last closed PR"
    else
      rm "$state/demo.meta"
    fi
    start_host "$home"
    wait_until 450 watcher_live "$home" || fail "$kind sweep watcher did not start"
    append_wake "$state" check ado-pr-sweep "$payload"
    if [ "$kind" = mixed ]; then
      # The fork's slower CI runners need headroom for this host/engine wait.
      wait_until 450 host_exited "$home" || fail 'multi-PR cleanup did not hand back'
      assert_grep 'handback: dispatch for demo' "$home/host.out" 'first live PR lost its dispatch'
      assert_grep 'handback: dispatch for other' "$home/host.out" 'second live PR lost its dispatch'
      [ "$(cat "$home/teardown-attempted")" = "$(printf 'demo\nother')" ] || fail 'sweep cleaned up an absent or non-merged owner'
      tasks='demo fleet fleet other'
    else
      # The fork's slower CI runners need headroom for this host/engine wait.
      wait_until 450 handled_at_least "$home" 1 || fail 'two closed PRs were not handled'
      [ ! -s "$home/host.rc" ] || fail 'closed multi-PR sweep handed back'
      [ ! -e "$home/teardown-attempted" ] || fail 'closed multi-PR sweep attempted teardown'
      tasks='fleet fleet'
    fi
    out=$(jq -sr '[.[].task] | sort | join(" ")' "$state/branch-outcomes.jsonl")
    [ "$out" = "$tasks" ] || fail "$kind sweep did not report every merged PR: $out"
    jq -es 'map(select(.task == "fleet")) | all(.verdict == "routine" and .silent == false)' "$state/branch-outcomes.jsonl" >/dev/null \
      || fail 'closed PRs did not produce visible routine notes'
    assert_grep 'merged-task=fleet' "$home/engine-call.1" 'closed PR resolution was not delivered'
    stop_home_processes "$home"
  done
  pass 'merged sweep: every merged PR in flattened mixed and closed-only rows is handled'
}

fm_test_run \
  test_park_exit_probe_uses_half_second_child_sleeps \
  test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main \
  test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue \
  test_engine_in_another_time_zone_handles_its_granted_rows \
  test_attended_captain_outcome_reaches_main_through_branch_outcomes \
  test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return \
  test_quiet_record_without_its_daemon_is_a_present_captain \
  test_attended_main_only_close_passes_straight_to_main \
  test_off_written_while_parked_passes_the_next_attended_close_to_main \
  test_main_only_pass_through_leaves_the_successor_watcher_running \
  test_attended_close_with_unidentified_main_session_passes_to_main \
  test_close_accepted_away_that_turns_attended_passes_to_main \
  test_attended_close_that_turns_main_only_before_its_turn_passes_to_main \
  test_primary_without_a_verified_mirror_runs_away_only \
  test_attended_wake_carries_the_dialog_mirror \
  test_dialog_bearing_files_are_owner_only \
  test_undelivered_dialog_is_fed_again_on_the_next_turn \
  test_attended_wake_with_an_unreadable_mirror_reaches_main \
  test_away_wake_is_handled_on_the_engine_and_never_reaches_main \
  test_away_turn_without_a_report_hands_the_wake_to_main \
  test_return_during_an_engine_turn_hands_its_outcomes_to_main \
  test_silent_outcomes_are_not_relayed_when_the_captain_returns \
  test_large_turn_relays_an_early_visible_outcome \
  test_outcome_lookup_failure_is_not_treated_as_silence \
  test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end \
  test_next_host_clears_a_turn_its_killed_predecessor_left \
  test_report_without_acknowledgement_hands_the_wake_to_main \
  test_return_during_a_failed_turn_still_hands_its_outcomes_to_main \
  test_incomplete_engine_result_hands_the_wake_to_main \
  test_away_report_classifies_main_actions \
  test_away_merge_handback_scopes_the_reported_lane \
  test_away_merge_handback_in_a_batch \
  test_away_explicit_decision_trigger_is_lane_local \
  test_away_derived_dispatch_is_once_per_turn_and_task \
  test_away_handback_survives_ack_and_resumes_host_after_main \
  test_away_worker_input_handback_and_captain_hold \
  test_away_handback_drains_only_the_handed_lane \
  test_away_multiple_handbacks_keep_one_complete_reason_line \
  test_herdr_endpoint_bindings_follow_crew_state_metadata \
  test_dispatch_endpoint_diagnostics_respect_caller_sink \
  test_quiet_words_reach_the_engine_and_report_now \
  test_routine_unsticking_closes_each_stop_without_main_handback \
  test_merged_sweep_skips_already_closed_tasks \
  test_merged_sweep_handles_every_report_in_a_row
