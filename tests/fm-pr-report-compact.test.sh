#!/usr/bin/env bash
# Behavioral battery for bin/fm-pr-report-compact (--stdin filter mode only;
# the az-backed mode is the same compact() with transport around it).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/bin/fm-pr-report-compact"
failures=0

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

ATTESTATION='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'

make_body() {  # <padding-chars> -> an assembled PR body on stdout
  local pad_len=$1
  printf '## Intent\n\nShip the change.\n\n## What Changed\n\nFiles.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n%s\n\n' "$ATTESTATION"
  printf '<details>\n<summary>✅ **intent** - passed</summary>\n\nok\n</details>\n\n'
  printf '<details>\n<summary>⚠️ **Review** - 3 issues (1 warning, 2 infos)</summary>\n\n%s\n</details>\n' "$(printf 'x%.0s' $(seq 1 "$pad_len"))"
}

# 1. An oversized body is compacted under the cap with the attestation verbatim.
big=$(make_body 4200)
out=$(printf '%s' "$big" | "$TOOL" --stdin) || fail "tool errored on oversized body"
[ -n "$out" ] || fail "oversized body must be rewritten"
[ "${#out}" -le 3900 ] || fail "compacted body still ${#out} chars"
printf '%s' "$out" | grep -qF "$ATTESTATION" || fail "attestation must survive byte-for-byte"
printf '%s' "$out" | grep -q -- "- ✅ intent - passed" || fail "surviving step summary must be one-lined"
printf '%s' "$out" | grep -q -- "- ⚠️ Review - 3 issues" || fail "review summary line must survive compaction"
printf '%s' "$out" | grep -q -- "- ✅ test - passed" || fail "steps without a details block must be reconstructed from the attestation"
printf '%s' "$out" | grep -qv "<details>" || fail "details blocks must be removed"

# 2. Intent/What Changed/Risk prefix stays verbatim.
printf '%s' "$out" | grep -q "^## Intent" || fail "Intent section must survive"
printf '%s' "$out" | grep -q "^## Risk Assessment" || fail "Risk section must survive"

# 3. A body that already fits is left alone (empty stdout, exit 0).
small=$(make_body 10)
out=$(printf '%s' "$small" | "$TOOL" --stdin) || fail "tool errored on fitting body"
[ -z "$out" ] || fail "a fitting body must not be rewritten"

# 4. A body carrying the ADO truncation mark is compacted even when short.
marked="$small
…(description truncated)"
out=$(printf '%s' "$marked" | "$TOOL" --stdin) || fail "tool errored on marked body"
[ -n "$out" ] || fail "a truncation-marked body must be rewritten"

if [ "$failures" -gt 0 ]; then
  echo "fm-pr-report-compact battery: $failures failure(s)" >&2
  exit 1
fi
echo "fm-pr-report-compact battery: OK"
