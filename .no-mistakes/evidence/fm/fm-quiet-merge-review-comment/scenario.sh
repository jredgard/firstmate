#!/usr/bin/env bash
# scenario.sh <name> <posture: quiet|away|attended> <record: complete|pending|none|unfinished> <threads: empty|present> [extra env...]
set -u
REPO=~/.no-mistakes/worktrees/551ff26a6b1c/01M5N1NT6CNQX557DWPADA0QVR
SRC=/tmp/fm-live-src
name=$1 posture=$2 record=$3 threads=$4
W=$(mktemp -d /tmp/fm-live-$name.XXXXXX)
LAB=$W/fmhome; UH=$W/userhome; export FORGE_DIR=$W/forge
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$UH/.no-mistakes" "$FORGE_DIR" "$W/fakebin"
cp "$SRC/az" "$SRC/curl" "$W/fakebin/"
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL='https://dev.azure.com/acme/Project%20One/_git/Backend/pullrequest/42'
# task worktree, home layout, task meta
git init -q -b main "$W/wt" && echo x > "$W/wt/README.md" && git -C "$W/wt" add . \
  && git -C "$W/wt" -c user.name=lab -c user.email=lab@example.invalid commit -qm init \
  && git -C "$W/wt" update-ref refs/remotes/origin/main HEAD
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf '%s\n' 22222222-2222-2222-2222-222222222222 > "$LAB/config/ado-reviewer-id"
printf '%s\n' window=fm-task-x1 "worktree=$W/wt" "project=$W/project" kind=ship branch=fm/example mode=no-mistakes > "$LAB/state/task-x1.meta"
# forge PR: attested description at the live head
python3 - "$FORGE_DIR" "$HEAD_SHA" "$threads" "${NO_ATTEST:-0}" <<'PY'
import json, sys
d, head, threads, no_attest = sys.argv[1:]
desc = ("## Summary\nExample change.\n\n<!-- no-mistakes-pipeline-attestation:v1 "
        + json.dumps({"head_sha": head, "steps": []}) + " -->\n")
if no_attest == "1": desc = "## Summary\nHand-made PR, no pipeline.\n"
json.dump({"description": desc, "head": head, "status": "active"}, open(f"{d}/pr.json", "w"))
t = []
if threads == "present":
    t = [{"author": "no-mistakes-lane", "comments": [{"content":
          "## no-mistakes review — recorded findings (full texts)\n<!-- fm-pr-report-compact:attestation-head:" + head + " -->\nposted by lane"}]}]
json.dump(t, open(f"{d}/threads.json", "w"))
PY
# run record (real no-mistakes schema)
if [ "$record" != none ]; then
python3 - "$UH/.no-mistakes/state.sqlite" "$SRC/schema.sql" "$URL" "$HEAD_SHA" "$record" <<'PY'
import json, sqlite3, sys
path, schema, url, head, record = sys.argv[1:]
db = sqlite3.connect(path); db.executescript(open(schema).read())
db.execute("INSERT INTO repos VALUES ('repo1', '/tmp/x', 'https://dev.azure.com/acme/Project%20One/_git/Backend', NULL, 'main', 1)")
rstatus = "completed" if record == "complete" else "running"
db.execute("""INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, submitted_head_sha,
  review_approved_head_sha, status, pr_url, last_pushed_sha, created_at, updated_at)
  VALUES ('01LABRUN', 'repo1', 'fm/example', ?, ?, ?, ?, ?, ?, ?, 1, 1)""",
  (head, "0"*40, head, head, rstatus, url, head))
review = "fixing" if record == "unfinished" else "completed"
pr_step = "running" if record == "pending" else "completed"
ci_step = "pending" if record == "pending" else "completed"
f1 = json.dumps({"findings": [{"id": "lab-finding-1", "severity": "warning", "file": "bin/example.sh",
     "line": 12, "description": "Guard skipped the empty-input case."}]})
for i, (step, st, fj) in enumerate([("review", review, '{"findings": []}'), ("test", "completed", None),
                                    ("pr", pr_step, None), ("ci", ci_step, None)]):
    db.execute("INSERT INTO step_results (id, run_id, step_name, step_order, status, findings_json, completed_at) VALUES (?, '01LABRUN', ?, ?, ?, ?, ?)",
               (f"sr-{step}", step, i, st, fj, 100 + i))
db.execute("INSERT INTO step_rounds (id, step_result_id, round, trigger_type, findings_json, reviewed_head_sha, fix_summary, duration_ms, created_at) VALUES ('rd1','sr-review',1,'initial',?,?,NULL,1000,10)", (f1, "c"*40))
db.execute("INSERT INTO step_rounds (id, step_result_id, round, trigger_type, findings_json, reviewed_head_sha, fix_summary, duration_ms, created_at) VALUES ('rd2','sr-review',2,'fix','{\"findings\": []}',?,'Handled the empty-input case.',1000,20)", (head,))
db.commit()
PY
fi
lab_env() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" HOME="$UH" FORGE_DIR="$FORGE_DIR" PATH="$W/fakebin:$PATH" "$@"
}
case "$posture" in
  quiet|away) lab_env FM_AFK_MODE=$posture "$REPO/bin/fm-afk-contract.sh" enter --words 'merge green PRs' >/dev/null || echo "mandate entry failed" ;;
esac
# optional background lane simulation: pipeline finishes PR/CI posting and posts its own comment
if [ "${LANE_POSTS_AFTER:-}" != "" ]; then
  ( sleep "$LANE_POSTS_AFTER"
    python3 - "$UH/.no-mistakes/state.sqlite" "$FORGE_DIR" "$HEAD_SHA" <<'PY'
import json, sqlite3, sys, time
db, d, head = sys.argv[1:]
t = json.load(open(f"{d}/threads.json"))
t.append({"author": "no-mistakes-lane", "comments": [{"content":
  "## no-mistakes review — recorded findings (full texts)\n<!-- fm-pr-report-compact:attestation-head:" + head + " -->\nposted by lane"}]})
json.dump(t, open(f"{d}/threads.json", "w"))
with open(f"{d}/trace.log", "a") as f: f.write(time.strftime('%H:%M:%S') + " LANE posted its own review comment\n")
c = sqlite3.connect(db); c.execute("UPDATE step_results SET status='completed' WHERE step_name IN ('pr','ci')")
c.execute("UPDATE runs SET status='completed'"); c.commit()
PY
  ) &
fi
echo "### scenario: $name  (posture=$posture record=$record threads=$threads${NO_ATTEST:+ no-attestation}${FORGE_POST_REFUSED:+ forge-refuses-post}${FM_SUPERVISION_ACTOR:+ actor=$FM_SUPERVISION_ACTOR}${WAIT:+ wait=$WAIT}${LANE_POSTS_AFTER:+ lane-posts-after=${LANE_POSTS_AFTER}s})"
echo "\$ FM_HOME=<lab> bin/fm-pr-merge.sh task-x1 $URL ${MERGE_ARGS:-}"
start=$SECONDS
lab_env ${FM_SUPERVISION_ACTOR:+FM_SUPERVISION_ACTOR=$FM_SUPERVISION_ACTOR} ${FORGE_POST_REFUSED:+FORGE_POST_REFUSED=$FORGE_POST_REFUSED} FM_PR_REVIEW_COMMENT_WAIT="${WAIT:-30}" "$REPO/bin/fm-pr-merge.sh" task-x1 "$URL" ${MERGE_ARGS:-} </dev/null 2>&1
rc=$?
wait
echo "[exit=$rc elapsed=$((SECONDS-start))s]"
echo "--- forge trace ---"; cat "$FORGE_DIR/trace.log" 2>/dev/null
echo "--- forge PR status: $(python3 -c "import json;print(json.load(open('$FORGE_DIR/pr.json'))['status'])")"
[ -f "$FORGE_DIR/completed.json" ] && echo "--- completion record: $(cat "$FORGE_DIR/completed.json")"
python3 - "$FORGE_DIR/threads.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
print(f"--- review-comment threads on PR: {len(t)}")
for x in t:
    if x.get("author") == "firstmate-merge-guard":
        print("--- comment posted by merge guard (status=%s):" % x.get("status"))
        print(x["comments"][0]["content"])
PY
echo "--- merge-authority record: $(sed -n 6p "$LAB/state/task-x1.merge-authority" 2>/dev/null || echo none)"
rm -rf "$W"
echo
