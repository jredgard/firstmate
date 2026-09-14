#!/usr/bin/env bash
# Behavioral battery for bin/fm-pr-report-compact.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/bin/fm-pr-report-compact"
failures=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

ATTESTATION='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
ATTESTATION_HEAD=d4aeca250cf6e5927915d23a55a7b51c2aac2d34
ROUND_MARKER="<!-- fm-pr-report-compact:attestation-head:$ATTESTATION_HEAD -->"

make_body() {  # <padding-chars> -> an assembled PR body on stdout
  local pad_len=$1
  printf '## What Changed\n\nFiles.\n\n## Intent\n\nShip the change.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n'
  printf '%s\n%s\n%s\n\n%s\n\n' \
    '- ✅ intent - passed' '- ✅ pr - passed' '- ⚠️ ci - pending' "$ATTESTATION"
  printf '<details>\n<summary>✅ **intent** - passed</summary>\n\nok\n</details>\n\n'
  printf '<details>\n<summary>⚠️ **Review** - 3 issues (1 warning, 2 infos)</summary>\n\n%s\n</details>\n' "$(printf 'x%.0s' $(seq 1 "$pad_len"))"
}

# Explicit help succeeds on stdout without writing stderr.
for help_flag in --help -h; do
  if "$TOOL" "$help_flag" > "$TEST_DIR/help.stdout" 2> "$TEST_DIR/help.stderr"; then
    grep -q '^Usage:$' "$TEST_DIR/help.stdout" || fail "$help_flag must print usage to stdout"
    [ ! -s "$TEST_DIR/help.stderr" ] || fail "$help_flag must not write stderr"
  else
    fail "$help_flag must exit zero"
  fi
done

# Genuine argument errors fail with usage on stderr and no stdout.
if "$TOOL" unexpected > "$TEST_DIR/error.stdout" 2> "$TEST_DIR/error.stderr"; then
  fail "bad arguments must exit nonzero"
else
  grep -q '^Usage:$' "$TEST_DIR/error.stderr" || fail "bad arguments must print usage to stderr"
  [ ! -s "$TEST_DIR/error.stdout" ] || fail "bad arguments must not write stdout"
fi

# 1. An old-format body gets canonical ordering and a fresh all-passed board.
big=$(make_body 4200)
out=$(printf '%s' "$big" | "$TOOL" --stdin) || fail "tool errored on oversized body"
[ -n "$out" ] || fail "oversized body must be rewritten"
[ "${#out}" -le 4000 ] || fail "normalized body still ${#out} chars"
printf '%s' "$out" | grep -qF "$ATTESTATION" || fail "attestation must survive byte-for-byte"
[ "$(printf '%s' "$out" | grep -Fxc "$ATTESTATION")" -eq 1 ] || fail "attestation must survive exactly once"
for step in intent review test pr ci; do
  [ "$(printf '%s' "$out" | grep -Fxc -- "- ✅ $step - passed")" -eq 1 ] || \
    fail "$step must have exactly one verified passed line"
done
if printf '%s' "$out" | grep -q -- '⚠️\|<details>'; then
  fail "stale board values and details blocks must be removed"
fi
headings=$(printf '%s' "$out" | grep '^## ' | tr '\n' '|')
[ "$headings" = '## Intent|## What Changed|## Risk Assessment|## Pipeline|' ] || \
  fail "sections must be emitted in canonical order"

# 2. Prose bullets that mention step names are not mistaken for board lines.
prose_body=$(printf '## Intent\n\nShip it.\n\n## What Changed\n\n- Added test - covers the new path\n- Renamed pr - update call sites\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n%s' "$ATTESTATION")
prose_out=$(printf '%s' "$prose_body" | "$TOOL" --stdin) || \
  fail "tool errored on prose bullets naming steps"
printf '%s' "$prose_out" | grep -qF -- '- Added test - covers the new path' || \
  fail "prose bullet naming a step must survive normalization"
printf '%s' "$prose_out" | grep -qF -- '- Renamed pr - update call sites' || \
  fail "second prose bullet naming a step must survive normalization"

# 3. A fitting body without a board is normalized, then reruns idempotently.
small=$(printf '## Intent\n\nShip the change.\n\n## What Changed\n\nFiles.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\nUpdates from no-mistakes.\n\n%s' "$ATTESTATION")
new_out=$(printf '%s' "$small" | "$TOOL" --stdin) || fail "tool errored on fitting body"
[ -n "$new_out" ] || fail "a fitting body without a board must be normalized"
printf '%s' "$new_out" | grep -q -- '- ✅ ci - passed' || \
  fail "a fitting body must gain the final CI status"
out=$(printf '%s' "$new_out" | "$TOOL" --stdin) || \
  fail "tool errored on an already-normalized body"
[ -z "$out" ] || fail "an already-normalized body must not be rewritten"

# 4. A near-cap head is trimmed without losing work-item tokens or Risk.
padding=$(printf 'verbose prose %.0s' $(seq 1 300))
near_cap=$(printf '## Intent\n\nKeep this first sentence. %s AB#55008\n\n## What Changed\n\n- A detailed implementation bullet.\n\n## Risk Assessment\n\nVerdict: Low.\n\n## Pipeline\n\n%s' "$padding" "$ATTESTATION")
near_out=$(printf '%s' "$near_cap" | "$TOOL" --stdin) || \
  fail "tool errored while trimming the near-cap head"
printf '%s' "$near_out" | python3 -c \
  'import sys; sys.exit(len(sys.stdin.read().encode("utf-16-le")) // 2 > 4000)' || \
  fail "trimmed near-cap body must fit ADO's UTF-16 cap"
printf '%s' "$near_out" | grep -qF 'AB#55008' || \
  fail "Intent trimming must retain AB# tokens"
printf '%s' "$near_out" | grep -qF 'Verdict: Low.' || fail "Risk must survive trimming"
printf '%s' "$near_out" | grep -qF "$ATTESTATION" || \
  fail "trimmed body must retain the exact attestation"

# 4a. Intent without sentence punctuation still has a bounded fallback.
runon=$(printf '## Intent\n\n%s AB#55009\n\n## What Changed\n\n- Small.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n%s' \
  "$(printf 'x%.0s' $(seq 1 4300))" "$ATTESTATION")
runon_out=$(printf '%s' "$runon" | "$TOOL" --stdin) || \
  fail "tool errored on an unpunctuated oversized Intent"
printf '%s' "$runon_out" | grep -qF 'See the commits for the complete intent.' || \
  fail "unpunctuated oversized Intent must use the bounded fallback"
printf '%s' "$runon_out" | grep -qF 'AB#55009' || \
  fail "bounded Intent fallback must retain work-item tokens"

# 4b. UTF-16 length, not code-point count, triggers astral-character trimming.
astral_body=$(python3 - "$ATTESTATION" <<'PY'
import sys

attestation = sys.argv[1]
prefix = "## Intent\n\nKeep this first sentence. "
suffix = "\n\n## What Changed\n\n- Bullet.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n" + attestation
board = "\n\n" + "\n".join(
    f"- ✅ {step} - passed" for step in ("intent", "review", "test", "pr", "ci")
)
rockets = 150
filler = 3995 - len(prefix) - len(suffix) - len(board) - rockets
body = prefix + "x" * filler + "🚀" * rockets + suffix
normalized = body + board
assert filler > 0 and len(normalized) <= 4000
assert len(normalized.encode("utf-16-le")) // 2 > 4000
print(body, end="")
PY
) || fail "astral fixture construction failed"
astral_out=$(printf '%s' "$astral_body" | "$TOOL" --stdin) || \
  fail "tool errored on astral near-cap body"
printf '%s' "$astral_out" | python3 -c \
  'import sys; sys.exit(len(sys.stdin.read().encode("utf-16-le")) // 2 > 4000)' || \
  fail "normalized astral body must fit the UTF-16 cap"

# 5. A truncated unclosed raw file fence becomes a stable Files-tab pointer.
dump_prefix=$'## Intent\n\nShip the file-list fix.\n\n## What Changed\n\n- Updated generated files.\n\n```text\n'
dump_suffix=$'\n…(description truncated)\n\n## Risk Assessment\n\nVerdict: Low.\n\n## Pipeline\n\n'
dump_suffix+="$ATTESTATION"
dump_source=$(printf 'src/generated/very-long-file-name.cs\n%.0s' $(seq 1 200))
truncated_dump="${dump_prefix}${dump_source:0:3000}${dump_suffix}"
dump_out=$(printf '%s' "$truncated_dump" | "$TOOL" --stdin) || \
  fail "tool errored on an unclosed changed-file dump"
printf '%s' "$dump_out" | grep -qF 'Full file list: see the Files tab.' || \
  fail "raw changed-file dump must become the Files-tab pointer"
if printf '%s' "$dump_out" | grep -q '```\|description truncated'; then
  fail "normalized file-list shape must contain no raw fence or truncation marker"
fi
printf '%s' "$dump_out" | grep -qF 'Verdict: Low.' || \
  fail "Risk must render outside the removed file-list fence"

# 5b. A properly closed text fence is author content and survives intact.
closed_fence=$(printf '## Intent\n\nShip it.\n\n## What Changed\n\n```text\nexample output line\n```\n\nAfter the fence.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n%s' "$ATTESTATION")
closed_out=$(printf '%s' "$closed_fence" | "$TOOL" --stdin) || \
  fail "tool errored on a closed text fence"
printf '%s' "$closed_out" | grep -qF 'example output line' || \
  fail "closed text fence content must survive normalization"
printf '%s' "$closed_out" | grep -qF 'After the fence.' || \
  fail "prose after a closed text fence must survive normalization"
if printf '%s' "$closed_out" | grep -qF 'Full file list: see the Files tab.'; then
  fail "closed text fence must not become the Files-tab pointer"
fi

# 6. A body carrying the ADO truncation mark is normalized when short.
marked="$small
…(description truncated)"
out=$(printf '%s' "$marked" | "$TOOL" --stdin) || fail "tool errored on marked body"
[ -n "$out" ] || fail "a truncation-marked body must be rewritten"

# Build a minimal no-mistakes state database and an az transport double so the
# remaining cases exercise the executable's public ADO-backed interface.
TEST_HOME="$TEST_DIR/home"
FAKE_BIN="$ROOT/tests/fixtures/fm-pr-report-compact"
AZ_TRACE="$TEST_DIR/az.trace"
AZ_POST_BODY="$TEST_DIR/post.json"
AZ_UPDATE_BODY="$TEST_DIR/update.txt"
AZ_DESCRIPTION_FILE="$TEST_DIR/description.txt"
EMPTY_THREADS="$TEST_DIR/empty-threads.json"
SAME_ROUND_THREADS="$TEST_DIR/same-round-threads.json"
OLDER_ROUND_THREADS="$TEST_DIR/older-round-threads.json"
LEGACY_THREADS="$TEST_DIR/legacy-threads.json"
mkdir -p "$TEST_HOME/.no-mistakes"
printf '%s' "$small" > "$AZ_DESCRIPTION_FILE"
printf '{"value":[]}\n' > "$EMPTY_THREADS"
printf '{"value":[{"comments":[{"content":"%s\\n%s\\nprior"}]}]}\n' \
  '## no-mistakes review — recorded findings (full texts)' "$ROUND_MARKER" \
  > "$SAME_ROUND_THREADS"
printf '{"value":[{"comments":[{"content":"%s\\n%s\\nprior"}]}]}\n' \
  '## no-mistakes review — recorded findings (full texts)' \
  '<!-- fm-pr-report-compact:attestation-head:older-head -->' \
  > "$OLDER_ROUND_THREADS"
printf '{"value":[{"comments":[{"content":"%s\\nprior"}]}]}\n' \
  '## no-mistakes review — recorded findings (full texts)' > "$LEGACY_THREADS"

python3 - "$TEST_HOME/.no-mistakes/state.sqlite" <<'PY'
import json
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  head_sha TEXT NOT NULL,
  submitted_head_sha TEXT,
  review_approved_head_sha TEXT,
  pr_url TEXT
);
CREATE TABLE step_results (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  step_name TEXT NOT NULL,
  findings_json TEXT,
  completed_at INTEGER
);
CREATE TABLE step_rounds (
  id TEXT PRIMARY KEY,
  step_result_id TEXT NOT NULL,
  round INTEGER NOT NULL,
  trigger_type TEXT NOT NULL,
  findings_json TEXT,
  reviewed_head_sha TEXT,
  fix_summary TEXT
);
""")
clean = json.dumps({"findings": []})
one = json.dumps({"findings": [{
    "id": "review-1",
    "severity": "warning",
    "file": "bin/example",
    "line": 7,
    "description": "Keep this full finding text.",
}]})
two = json.dumps({"findings": [
    {
        "id": "review-1",
        "severity": "warning",
        "file": "bin/example",
        "line": 7,
        "description": "Keep this full finding text.",
    },
    {
        "id": "review-2",
        "severity": "info",
        "file": "bin/example",
        "line": 9,
        "description": "Second residual finding text.",
    },
]})
failing = json.dumps({"findings": [
    {
        "id": "review-1",
        "severity": "warning",
        "file": "bin/example",
        "line": 7,
        "description": "Keep this full finding text.",
    },
    {
        "severity": "info",
        "file": "bin/example",
        "line": 11,
        "description": "Unnamed persisting finding.",
    },
]})
flap = json.dumps({"findings": [{
    "id": "flap-1",
    "severity": "warning",
    "file": "bin/example",
    "line": 3,
    "description": "Reappearing finding text.",
}]})
for pr_id, run_id, result_id, head, payload in (
    ("111", "run-clean", "result-clean", "head-final", clean),
    ("222", "run-completed", "result-completed", "head-completed", clean),
    ("333", "run-findings", "result-findings", "head-findings", one),
    ("555", "run-multi", "result-multi", "head-multi", two),
    ("666", "run-failedfix", "result-failedfix", "head-ff-2", failing),
    ("777", "run-flap", "result-flap", "head-flap-3", flap),
):
    db.execute(
        "INSERT INTO runs VALUES (?, ?, ?, ?, ?)",
        (run_id, "head-start", head, head,
         f"https://dev.azure.com/org/project/_git/repo/pullrequest/{pr_id}"),
    )
    db.execute(
        "INSERT INTO step_results VALUES (?, ?, 'review', ?, 1)",
        (result_id, run_id, payload),
    )
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-clean-1", "result-clean", 1, "initial", one, "head-start", None),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-clean-2", "result-clean", 2, "auto_fix", clean, "head-final",
     "resolved review-1"),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-completed", "result-completed", 1, "initial", clean,
     "head-completed", None),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-findings", "result-findings", 1, "initial", one,
     "head-findings", None),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-multi", "result-multi", 1, "initial", two,
     "head-multi", None),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-ff-1", "result-failedfix", 1, "initial", failing,
     "head-ff-1", None),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-ff-2", "result-failedfix", 2, "auto_fix", failing,
     "head-ff-2", "attempted tightening the guard"),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-flap-1", "result-flap", 1, "initial", flap,
     "head-flap-1", None),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-flap-2", "result-flap", 2, "auto_fix", clean,
     "head-flap-2", "moved the guard earlier"),
)
db.execute(
    "INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("round-flap-3", "result-flap", 3, "auto_fix", flap,
     "head-flap-3", None),
)
db.commit()
PY

export TEST_HOME FAKE_BIN AZ_TRACE AZ_POST_BODY AZ_UPDATE_BODY AZ_DESCRIPTION_FILE

run_pr() {  # <id> <status> <threads-file> [policy-status] [pr-exists] [blocking] [policy-shape]
  HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" AZ_PR_STATUS="$2" \
    AZ_POLICY_STATUS="${4:-approved}" AZ_PR_EXISTS="${5:-true}" \
    AZ_POLICY_BLOCKING="${6:-true}" AZ_POLICY_SHAPE="${7:-canonical}" \
    AZ_THREADS_FILE="$3" "$TOOL" https://dev.azure.com/org "$1"
}

# 7. A clean review posts a closed summary and normalizes a fitting body.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
clean_output=$(run_pr 111 active "$EMPTY_THREADS") || fail "clean PR run failed"
tick='`'
grep -qF "Run ID: ${tick}run-clean${tick}" "$AZ_POST_BODY" || fail "clean comment must name the run"
grep -qF "$ROUND_MARKER" "$AZ_POST_BODY" || fail "review comment must identify its attestation round"
grep -qF "Reviewed head: ${tick}head-final${tick}" "$AZ_POST_BODY" || fail "clean comment must name the reviewed head"
grep -qF 'Review rounds: 2' "$AZ_POST_BODY" || fail "clean comment must count review rounds"
grep -qF "Round 1: trigger ${tick}initial${tick}; outcome: 1 finding" "$AZ_POST_BODY" || fail "clean comment must summarize the initial round"
grep -qF "Round 2: trigger ${tick}auto_fix${tick}; outcome: no findings" "$AZ_POST_BODY" || fail "clean comment must summarize the clean final round"
grep -qF "${tick}review-1${tick} (warning): Keep this full finding text.; fixed in round 2: resolved review-1" "$AZ_POST_BODY" || fail "multi-round comment must explain each finding and attribute its fix"
grep -qF 'Verdict: **no residual findings.**' "$AZ_POST_BODY" || fail "clean comment must state the residual verdict"
grep -qF '"status": "closed"' "$AZ_POST_BODY" || fail "review comment thread must be closed"
printf '%s' "$clean_output" | grep -qF 'description normalized to' || \
  fail "fitting active PR without a board must be normalized"
grep -qF -- '- ✅ ci - passed' "$AZ_UPDATE_BODY" || \
  fail "ADO update must receive the final board"
grep -qF "$ATTESTATION" "$AZ_UPDATE_BODY" || \
  fail "ADO update must retain the exact attestation"

# 8. A completed PR gets a newer-round comment but no description update.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
printf '%s' "$big" > "$AZ_DESCRIPTION_FILE"
completed_output=$(run_pr 222 completed "$OLDER_ROUND_THREADS") || fail "completed PR run failed"
grep -q -- '--http-method POST' "$AZ_TRACE" || fail "completed PR must still receive a newer-round review comment"
grep -qF "$ROUND_MARKER" "$AZ_POST_BODY" || fail "completed PR comment must identify the current attestation round"
grep -qF 'description left as-merged' <<< "$completed_output" || fail "completed PR must report its description was left as-merged"
if grep -q '^repos pr update' "$AZ_TRACE" || [ -s "$AZ_UPDATE_BODY" ]; then
  fail "completed PR description must not be updated"
fi
if grep -q '^repos pr policy list' "$AZ_TRACE"; then
  fail "completed PR must not require an active-only Build policy check"
fi
printf '%s' "$new_out" > "$AZ_DESCRIPTION_FILE"

# 9. Current-attestation comment and normalized description are idempotent.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
idempotent_output=$(run_pr 111 active "$SAME_ROUND_THREADS") || fail "idempotent PR run failed"
if grep -q -- '--http-method POST' "$AZ_TRACE"; then
  fail "same-round review thread must suppress a duplicate post"
fi
printf '%s' "$idempotent_output" | grep -qF 'findings comment already posted' || fail "existing thread skip must be reported"
printf '%s' "$idempotent_output" | grep -qF 'description already normalized, not rewritten' || \
  fail "normalized description skip must be reported"
[ ! -s "$AZ_UPDATE_BODY" ] || fail "fully normalized rerun must produce no update"

# 7b. A review thread for an older attestation does not suppress the new round.
: > "$AZ_TRACE"
run_pr 111 active "$OLDER_ROUND_THREADS" >/dev/null || fail "newer-round PR run failed"
grep -q -- '--http-method POST' "$AZ_TRACE" || fail "newer attestation must receive a new review comment"
grep -qF "$ROUND_MARKER" "$AZ_POST_BODY" || fail "newer-round comment must carry the current marker"

# 7c. A markerless legacy review thread does not suppress the current round.
: > "$AZ_TRACE"
run_pr 111 active "$LEGACY_THREADS" >/dev/null || fail "legacy-thread PR run failed"
grep -q -- '--http-method POST' "$AZ_TRACE" || fail "markerless legacy thread must receive the current review comment"
grep -qF "$ROUND_MARKER" "$AZ_POST_BODY" || fail "legacy follow-up comment must carry the current marker"

# 8. Residual findings retain their full text below the same summary header.
: > "$AZ_TRACE"
run_pr 333 active "$EMPTY_THREADS" >/dev/null || fail "findings PR run failed"
findings_content=$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1]))["comments"][0]["content"])' \
  "$AZ_POST_BODY")
grep -qF '### Review summary' "$AZ_POST_BODY" || fail "findings comment must include the review summary header"
grep -qF "${tick}review-1${tick} (warning): Keep this full finding text." "$AZ_POST_BODY" || fail "round summary must name and explain residual findings"
grep -qF "### review-1 — warning ${tick}bin/example:7${tick}" <<< "$findings_content" || fail "finding heading must retain the current full-text format"
grep -qF 'Keep this full finding text.' "$AZ_POST_BODY" || fail "finding description must remain in full"
grep -qF 'Verdict: **1 finding remains.**' "$AZ_POST_BODY" || fail "singular residual verdict must read '1 finding remains.'"

# 8b. Multiple residual findings keep the plural verdict wording.
: > "$AZ_TRACE"
run_pr 555 active "$EMPTY_THREADS" >/dev/null || fail "multi-findings PR run failed"
grep -qF 'Verdict: **2 findings remain.**' "$AZ_POST_BODY" || fail "plural residual verdict must read '2 findings remain.'"
grep -qF 'Second residual finding text.' "$AZ_POST_BODY" || fail "each residual finding must remain in full"

# 8c. A failing fix keeps its fix_summary on the round line, never as a
# 'fixed in round' attribution, and id-less findings are never attributed.
: > "$AZ_TRACE"
run_pr 666 active "$EMPTY_THREADS" >/dev/null || fail "failing-fix PR run failed"
grep -qF "Round 2: trigger ${tick}auto_fix${tick}; outcome: 2 findings; reviewed head: ${tick}head-ff-2${tick}; fix attempted: attempted tightening the guard" "$AZ_POST_BODY" || \
  fail "failing fix_summary must survive on its round line as a fix attempt"
if grep -qF 'fixed in round' "$AZ_POST_BODY"; then
  fail "a persisting finding must never be labeled fixed"
fi
grep -qF "${tick}unnamed-finding${tick} (info): Unnamed persisting finding." "$AZ_POST_BODY" || \
  fail "id-less findings must still be narrated"
grep -qF 'Verdict: **2 findings remain.**' "$AZ_POST_BODY" || \
  fail "failing-fix run must keep its residual verdict"

# 8d. A finding that disappears then reappears under the same id is residual,
# not fixed; the flapped round keeps its fix_summary as an attempt.
: > "$AZ_TRACE"
run_pr 777 active "$EMPTY_THREADS" >/dev/null || fail "flapping PR run failed"
if grep -qF 'fixed in round' "$AZ_POST_BODY"; then
  fail "a flapping finding must never contradict the residual verdict"
fi
grep -qF "Round 2: trigger ${tick}auto_fix${tick}; outcome: no findings; reviewed head: ${tick}head-flap-2${tick}; fix attempted: moved the guard earlier" "$AZ_POST_BODY" || \
  fail "flapped round must keep its fix_summary as a fix attempt"
grep -qF "Round 3: trigger ${tick}auto_fix${tick}; outcome: 1 finding" "$AZ_POST_BODY" || \
  fail "reappearing finding must be listed under its own round"
grep -qF 'Verdict: **1 finding remains.**' "$AZ_POST_BODY" || \
  fail "flapping run must keep its residual verdict"

# 9. Missing local run state is reported without crashing.
EMPTY_HOME="$TEST_DIR/empty-home"
mkdir -p "$EMPTY_HOME"
missing_output=$(HOME="$EMPTY_HOME" PATH="$FAKE_BIN:$PATH" AZ_PR_STATUS=active \
  AZ_THREADS_FILE="$EMPTY_THREADS" "$TOOL" https://dev.azure.com/org 444) || \
  fail "missing-state PR run failed"
printf '%s' "$missing_output" | grep -qF 'review comment could not be built: state database not found' || \
  fail "missing-state reason must be reported"

# 11. A non-approved blocking Build policy fails before either kind of write.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
printf '%s' "$small" > "$AZ_DESCRIPTION_FILE"
if nongreen_output=$(run_pr 111 active "$EMPTY_THREADS" queued 2>&1); then
  fail "non-green Build policy must fail"
fi
printf '%s' "$nongreen_output" | grep -qF \
  'CI was not verified green for PR 111; blocking Build policy status: queued' || \
  fail "non-green refusal must name the Build policy state"
if grep -q -- '--http-method POST\|repos pr update' "$AZ_TRACE" || \
    [ -s "$AZ_UPDATE_BODY" ]; then
  fail "non-green Build policy must cause zero writes"
fi

# 11b. A non-blocking Build policy does not block a green normalization claim.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
nonblocking_output=$(run_pr 111 active "$SAME_ROUND_THREADS" queued true false) || \
  fail "non-blocking Build policy run failed"
printf '%s' "$nonblocking_output" | grep -qF 'description normalized to' || \
  fail "non-blocking Build policy must not block normalization"
grep -qF -- '- ✅ ci - passed' "$AZ_UPDATE_BODY" || \
  fail "non-blocking policy run must write the final board"

# 11c. An alias-shaped policy (displayName only, top-level type, string
# isBlocking) is not a Build-policy match: only the exact well-known type GUID
# at configuration.type.id with a JSON-boolean isBlocking gates normalization.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
alias_output=$(run_pr 111 active "$SAME_ROUND_THREADS" queued true true alias) || \
  fail "alias-shaped policy run failed"
printf '%s' "$alias_output" | grep -qF 'description normalized to' || \
  fail "alias-shaped policy must not be matched as a blocking Build policy"
grep -qF -- '- ✅ ci - passed' "$AZ_UPDATE_BODY" || \
  fail "alias-shaped policy run must write the final board"

# 12. A missing PR fails existence verification before any write.
: > "$AZ_TRACE"
: > "$AZ_UPDATE_BODY"
if missing_pr_output=$(run_pr 111 active "$EMPTY_THREADS" approved false 2>&1); then
  fail "missing PR verification must fail"
fi
printf '%s' "$missing_pr_output" | grep -qF \
  'PR 111 could not be verified as existing' || \
  fail "missing PR refusal must name the existence check"
printf '%s' "$missing_pr_output" | grep -qF 'pull request not found' || \
  fail "missing PR refusal must surface az stderr"
if grep -q -- '--http-method POST\|repos pr update' "$AZ_TRACE" || \
    [ -s "$AZ_UPDATE_BODY" ]; then
  fail "missing PR must cause zero writes"
fi

if [ "$failures" -gt 0 ]; then
  echo "fm-pr-report-compact battery: $failures failure(s)" >&2
  exit 1
fi
echo "fm-pr-report-compact battery: OK"
