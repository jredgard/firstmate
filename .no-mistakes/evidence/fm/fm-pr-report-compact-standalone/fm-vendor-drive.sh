#!/usr/bin/env bash
# Drive the vendored fm-pr-report-compact payload alone in a Factory-like tooling/ dir.
set -u
REPO=$1; REV=$2
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/factory/tooling" "$W/onlypy"
git -C "$REPO" show "$REV:bin/fm-pr-report-compact" > "$W/factory/tooling/fm-pr-report-compact"
chmod +x "$W/factory/tooling/fm-pr-report-compact"
ln -s "$(python3 -c "import sys; print(sys.executable)")" "$W/onlypy/python3"
T="$W/factory/tooling/fm-pr-report-compact"
echo "### payload $REV ($(git -C "$REPO" rev-parse --short "$REV"))"
echo "\$ ls tooling/"; ls "$W/factory/tooling"
A='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"lint","status":"skipped"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
P='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
body() { printf '## Intent\n\nShip it.\n\n## What Changed\n\nFiles.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n- ✅ intent - passed\n\n%s\n' "$1"; }
run() { # label env-path args...
  local label=$1 pathv=$2 input=$3; shift 3
  echo; echo "--- $label"; echo "\$ PATH=$pathv python3 -I -S tooling/fm-pr-report-compact $*"
  printf '%s' "$input" | env -i PATH="$pathv" HOME="$W" "$W/onlypy/python3" -I -S "$T" "$@" > "$W/o" 2> "$W/e"; local s=$?
  echo "exit=$s"; echo "[stdout]"; cat "$W/o"; echo "[stderr]"; cat "$W/e"
}
run "registered lint skip, python-only PATH (no bash)" "$W/onlypy" "$(body "$A")" --stdin --nm-skip lint
run "registered lint skip, full PATH" "$PATH" "$(body "$A")" --stdin --nm-skip lint
run "omitted skip, all steps passed" "$W/onlypy" "$(body "$P")" --stdin
run "explicit empty skip, all steps passed" "$W/onlypy" "$(body "$P")" --stdin --nm-skip ''
run "adversarial: --nm-skip ci must exit 2" "$W/onlypy" "$(body "$P")" --stdin --nm-skip ci
run "adversarial: --nm-skip 'lint,ci' must exit 2" "$W/onlypy" "$(body "$P")" --stdin --nm-skip 'lint,ci'
run "adversarial: --nm-skip ' lint' must exit 2" "$W/onlypy" "$(body "$P")" --stdin --nm-skip ' lint'
run "adversarial: unregistered lint skip refused" "$W/onlypy" "$(body "$A")" --stdin
run "adversarial: invalid skip refused before az in ADO mode (no az on PATH)" "$W/onlypy" "" https://dev.azure.com/org 123 --nm-skip review
