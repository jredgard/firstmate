#!/usr/bin/env bash
# Live drive of bin/fm-pr-report-compact against a disposable HOME + az transport double.
set -u
ROOT=$1; LAB=$2; BASE_TOOL=$3
TOOL="$ROOT/bin/fm-pr-report-compact"
export AZ_TRACE="$LAB/az.trace" AZ_POST_BODY="$LAB/post.json" AZ_UPDATE_BODY="$LAB/update.txt" AZ_DESCRIPTION_FILE="$LAB/description.txt"
THREADS="$LAB/threads.json"; printf '{"value":[]}\n' > "$THREADS"
mkdir -p "$LAB/home/.no-mistakes"
python3 - "$LAB/home/.no-mistakes/state.sqlite" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE runs (id TEXT PRIMARY KEY, head_sha TEXT NOT NULL, submitted_head_sha TEXT, review_approved_head_sha TEXT, pr_url TEXT);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, findings_json TEXT, completed_at INTEGER);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL, trigger_type TEXT NOT NULL, findings_json TEXT, reviewed_head_sha TEXT, fix_summary TEXT);
""")
clean = json.dumps({"findings": []})
db.execute("INSERT INTO runs VALUES ('run-58753','h0','hfinal','hfinal','https://dev.azure.com/org/Mosaiq/_git/Mosaiq.Infrastructure/pullrequest/58753')")
db.execute("INSERT INTO step_results VALUES ('res-58753','run-58753','review',?,1)", (clean,))
db.execute("INSERT INTO step_rounds VALUES ('rd-1','res-58753',1,'initial',?,'hfinal',NULL)", (clean,))
db.commit()
PY
ATT='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"aaaabbbbccccddddeeeeffff0000111122223333","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"lint","status":"skipped"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
desc() { printf '## Intent\n\nGrant EasyAuth access for estate S2a.\n\n## What Changed\n\nAdded role grants.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\nUpdates from no-mistakes.\n\n- ✅ intent - passed\n- ⏭️ lint - skipped\n- ⚠️ ci - pending\n\n%s' "${1:-$ATT}" > "$AZ_DESCRIPTION_FILE"; }
reset() { : > "$AZ_TRACE"; : > "$AZ_UPDATE_BODY"; : > "$AZ_POST_BODY"; }
az_run() { # <policy-status> <tool> args...
  local pol=$1; shift
  env -u FM_HOME -u FM_TASK_ID HOME="$LAB/home" PATH="$ROOT/tests/fixtures/fm-pr-report-compact:$PATH" \
    AZ_PR_STATUS=active AZ_POLICY_STATUS="$pol" AZ_THREADS_FILE="$THREADS" "$@"
}
dod_cmd() { # <nm_skip> -> generated ADO compaction command
  bash -c '. "$1"; fm_dod_block no-mistakes s2a-grants fm/s2a-grants none "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$1" \
    | grep -o '`fm-pr-report-compact [^`]*`' | tr -d '`'
}
show() { echo "--- az calls:"; python3 -c 'import re,sys;print(re.sub(r"--description .*?--query","--description <body> --query",open(sys.argv[1]).read(),flags=re.S),end="")' "$AZ_TRACE" | cut -c1-110
  if [ -s "$AZ_POST_BODY" ]; then echo "--- review comment posted: yes"; else echo "--- review comment posted: no"; fi
  if [ -s "$AZ_UPDATE_BODY" ]; then echo "--- description update written; board:"; grep -E '^- (✅|⏭️|⚠️)' "$AZ_UPDATE_BODY"; else echo "--- description update written: no"; fi; }

echo "===== S0 REPRO (base commit tool d9da4de): PR 58753 shape, lint skipped, registry grants lint"
desc; reset
az_run approved "$BASE_TOOL" https://dev.azure.com/org 58753; echo "exit=$?"; show

echo; echo "===== S1 registered lint skip: DoD (nm_skip=lint) generated command, run verbatim"
CMD=$(dod_cmd lint); echo "DoD renders: $CMD"
desc; reset
read -r -a argv <<< "$CMD"; argv[1]=https://dev.azure.com/org; argv[2]=58753; argv[0]=$TOOL
az_run approved "${argv[@]}"; echo "exit=$?"; show
echo "--- attestation preserved byte-for-byte: $(grep -cF "$ATT" "$AZ_UPDATE_BODY")"
cp "$AZ_UPDATE_BODY" "$LAB/normalized-58753.md"

echo; echo "===== S1b rerun on already-normalized description is idempotent"
cp "$LAB/normalized-58753.md" "$AZ_DESCRIPTION_FILE"; reset
printf '{"value":[{"comments":[{"content":"%s"}]}]}\n' "$(grep -o '<!-- fm-pr-report-compact:attestation-head:[^>]*-->' "$LAB/post.json.keep" 2>/dev/null)" >/dev/null
az_run approved "${argv[@]}"; echo "exit=$?"; show

echo; echo "===== S2 unregistered skip: DoD (nm_skip empty) generated command, lint attested skipped"
CMD=$(dod_cmd ''); echo "DoD renders: $CMD"
desc; reset
read -r -a argv <<< "$CMD"; argv[1]=https://dev.azure.com/org; argv[2]=58753; argv[0]=$TOOL
az_run approved "${argv[@]}"; echo "exit=$?"; show

echo; echo "===== S3 adversarial: ungrantable --nm-skip values"
for v in review test ci 'lint,ci' Lint; do desc; reset
  az_run approved "$TOOL" https://dev.azure.com/org 58753 --nm-skip "$v"; echo "  --nm-skip '$v' exit=$? az_calls=$(wc -l < "$AZ_TRACE") update=$([ -s "$AZ_UPDATE_BODY" ] && echo yes || echo no)"
done

echo; echo "===== S4 adversarial: lint registered, but attested test is skipped (not granted)"
TC='{"step":"test","status":"completed"}'; TS='{"step":"test","status":"skipped"}'; desc "${ATT/"$TC"/"$TS"}"; grep -o '"test","status":"[a-z]*"' "$AZ_DESCRIPTION_FILE"; reset
az_run approved "$TOOL" https://dev.azure.com/org 58753 --nm-skip lint; echo "exit=$?"; show

echo; echo "===== S4b adversarial: lint registered, but attested lint FAILED"
desc "${ATT/\"lint\",\"status\":\"skipped\"/\"lint\",\"status\":\"failed\"}"; reset
az_run approved "$TOOL" https://dev.azure.com/org 58753 --nm-skip lint; echo "exit=$?"; show

echo; echo "===== S5 adversarial: lint registered, Build policy queued (CI not green)"
desc; reset
az_run queued "$TOOL" https://dev.azure.com/org 58753 --nm-skip lint; echo "exit=$?"; show

echo; echo "===== S6 --stdin filter with registered skip"
desc; "$TOOL" --stdin --nm-skip lint < "$AZ_DESCRIPTION_FILE" | grep -E '^- (✅|⏭️)'; echo "exit=${PIPESTATUS[0]}"
