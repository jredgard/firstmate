#!/usr/bin/env bash
# Run the attended supervision-host live guard on a disposable copy of one git ref.
# Usage: attended-live-at-ref.sh <repo> <ref> <log>
set -u
repo=$1 ref=$2 log=$3
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-ref-ctl.XXXXXX")
git -C "$repo" archive "$ref" | tar -x -C "$T"
git -C "$T" init -q -b main && git -C "$T" add -A && git -C "$T" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m "ref-$ref"
( cd "$T" && env -u NO_MISTAKES_GATE FM_SUPERVISION_HOST_ATTENDED_LIVE_E2E=1 timeout 900 bash tests/fm-supervision-host-attended-live-e2e.test.sh ) > "$log" 2>&1
rc=$?
rm -rf "$T"
echo "ref=$ref exit=$rc $(grep -E '^(ok|not ok)' "$log" | cut -c1-200)"
