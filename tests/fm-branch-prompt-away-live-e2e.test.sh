#!/usr/bin/env bash
# Opt-in development-only model interpretation probe for the final emitted
# supervision prompt and away wake. No tools are exposed and no forge is
# contacted: the real Claude engine decides its next action from fixture
# observations. Portable CI checks emitted interfaces and guarded commands;
# this credentialed probe checks interpretation, not source prompt substrings.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_BRANCH_PROMPT_AWAY_LIVE_E2E claude node jq
LAB=$(fm_test_tmproot fm-branch-prompt-away-live)
VERSION=$(claude --version | head -n 1)
mkdir -p "$LAB/home/state" "$LAB/home/config"
WORDS='pr merge, approve and complete authority for devops and github. Use recommended and sitrep when back. Ensure we move the needle and not wait on 1 pipeline hold'
FM_HOME="$LAB/home" "$ROOT/bin/fm-afk-contract.sh" enter --words "$WORDS" > "$LAB/readback"
"$ROOT/bin/fm-branch-prompt.sh" > "$LAB/system-prompt"
SCHEMA='{"type":"object","properties":{"next_action":{"type":"string","enum":["synchronous_merge","hold"]},"verdict":{"type":"string","enum":["captain","routine"]},"command":{"type":"string"}},"required":["next_action","verdict","command"],"additionalProperties":false}'

probe() {
  local name=$1 observations=$2 expected=$3
  printf 'check: PR ready: demo\n' | FM_HOME="$LAB/home" node "$ROOT/bin/fm-branch-dispatch.mjs" \
    wake-prompt --report 'the bin/fm-branch-report.sh command' --away --readback-file "$LAB/readback" > "$LAB/$name.wake"
  cat >> "$LAB/$name.wake" <<EOF

Development-only decision probe: tools are unavailable, so do not execute or claim any action. The following observations are the already-completed drain, task lease claim and live forge read for this wake. Return the next action you would take, its command, and the outcome verdict after that action succeeds, as structured output.
Task demo belongs to the Mosaiq lane, mode=no-mistakes, yolo=off, with no captain hold or destructive action. Its recorded PR URL is https://dev.azure.com/acme/Project%20One/_git/Backend/pullrequest/42 and its live head is aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa. The worker's no-mistakes CI monitor is still running.
$observations
EOF
  (cd "$LAB" && claude -p "$(cat "$LAB/$name.wake")" --safe-mode \
    --system-prompt-file "$LAB/system-prompt" --tools '' --strict-mcp-config \
    --no-session-persistence --output-format json \
    --json-schema "$SCHEMA") > "$LAB/$name.result" 2> "$LAB/$name.stderr" \
    || fail "decision probe $name failed ($VERSION): $(cat "$LAB/$name.result") $(cat "$LAB/$name.stderr")"
  jq -e --arg action "$expected" '.is_error == false and .structured_output.next_action == $action and
    .structured_output.verdict == "captain"' "$LAB/$name.result" >/dev/null \
    || fail "decision probe $name chose the wrong action ($VERSION): $(cat "$LAB/$name.result")"
  if [ "$expected" = synchronous_merge ]; then
    jq -e '.structured_output.command == "bin/fm-pr-merge.sh demo https://dev.azure.com/acme/Project%20One/_git/Backend/pullrequest/42"' \
      "$LAB/$name.result" >/dev/null || fail "decision probe $name bypassed the guarded merge ($VERSION)"
  fi
  pass "away decision $name ($VERSION): $expected"
}

probe green 'The PR is active, not draft, mergeStatus=succeeded. Build and all required policies are approved at that live head.' synchronous_merge
probe red 'The PR is active, not draft, mergeStatus=succeeded. The required Build policy is rejected at that live head.' hold
probe unreported 'The PR is active, not draft, mergeStatus=succeeded. The required Build policy has not reported at that live head.' hold
FM_HOME="$LAB/home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
FM_HOME="$LAB/home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'you may merge green PRs only for the Windows lane' > "$LAB/readback"
probe other-lane 'The PR is active, not draft, mergeStatus=succeeded. Build and all required policies are approved at that live head.' hold
