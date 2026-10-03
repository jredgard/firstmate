#!/usr/bin/env bash
# Public-interface conflict radar tests: Git paths, classification, missing
# worktrees, bounded forge pagination, deduplication and memory reconciliation.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-conflict-radar)
HOME_FIXTURE="$TMP_ROOT/home"
TOOLS="$TMP_ROOT/tools"
PROJECT_FIXTURE="$TMP_ROOT/shared/app"
mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data" "$HOME_FIXTURE/projects" "$TOOLS"
git init -q -b main "$PROJECT_FIXTURE"
git -C "$PROJECT_FIXTURE" remote add origin git@ssh.dev.azure.com:v3/fixture/project/app
export FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" FM_DATA_OVERRIDE="$HOME_FIXTURE/data"
export RADAR_FIXTURE="$TMP_ROOT/forge" RADAR_CALLS="$TMP_ROOT/calls"
mkdir -p "$RADAR_FIXTURE"
printf '[]\n' > "$RADAR_FIXTURE/prs.json"
printf '%s\n' '- app [ledgers=golden/questions.json direct-PR +yolo branch=ship/] - fixture' > "$FM_DATA_OVERRIDE/projects.md"

cat > "$TOOLS/gh-axi" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$RADAR_CALLS"
[ ! -e "$RADAR_FIXTURE/fail" ] || exit 1
case "$3" in */files\?*) [ ! -e "$RADAR_FIXTURE/files-fail" ] || exit 1 ;; esac
case "$3" in
  */pulls\?*) file="$RADAR_FIXTURE/prs.json" ;;
  */pulls/7/files*)
    if [ -e "$RADAR_FIXTURE/pages" ]; then
      case "$3" in *page=1) file="$RADAR_FIXTURE/files-page1.json" ;; *page=2) file="$RADAR_FIXTURE/files-page2.json" ;; *) exit 1 ;; esac
    else file="$RADAR_FIXTURE/files.json"; fi ;;
  */pulls/7) file="$RADAR_FIXTURE/state.json" ;;
  *) exit 1 ;;
esac
printf 'api_response:\n  body: %s\n  truncated: false\n' "$(jq -r '@base64' "$file")"
EOF
chmod +x "$TOOLS/gh-axi"
export PATH="$TOOLS:$PATH"

for worker in alpha beta; do
  worktree="$TMP_ROOT/$worker"
  git init -q -b main "$worktree"
  git -C "$worktree" config user.email fixture@example.com
  git -C "$worktree" config user.name Fixture
  mkdir -p "$worktree/golden"
  printf 'base\n' > "$worktree/README.md"
  printf '{}\n' > "$worktree/package.json"
  printf 'base\n' > "$worktree/code.sh"
  printf '{}\n' > "$worktree/golden/questions.json"
  git -C "$worktree" add .
  git -C "$worktree" commit -qm base
  git -C "$worktree" update-ref refs/remotes/origin/main HEAD
  git -C "$worktree" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$worktree" remote add origin https://github.com/fixture/app.git
  git -C "$worktree" checkout -qb "ship/$worker"
  printf 'project=%s\nworktree=%s\nkind=ship\nbranch=ship/%s\n' "$PROJECT_FIXTURE" "$worktree" "$worker" > "$FM_STATE_OVERRIDE/$worker.meta"
done
RADAR="$ROOT/bin/fm-conflict-radar.sh"
run_radar() { bash "$RADAR" --json app > "$TMP_ROOT/result.json"; }
assert_json() { jq -e "$1" "$TMP_ROOT/result.json" >/dev/null || fail "$2"; pass "$2"; }

[ "$(bash "$ROOT/bin/fm-project-mode.sh" --ledgers app)" = golden/questions.json ] || fail 'registry ledgers'
[ "$(bash "$ROOT/bin/fm-project-mode.sh" app)" = 'direct-PR on' ] || fail 'ledger token changed delivery mode'
[ "$(bash "$ROOT/bin/fm-project-mode.sh" --branch-prefix app)" = 'ship/' ] || fail 'ledger token changed branch'
[ -z "$(bash "$ROOT/bin/fm-project-mode.sh" --ledgers absent 2>/dev/null)" ] || fail 'absent ledger list'
pass 'order-independent ledger token preserves posture and branch queries'

run_radar
assert_json '.projects[0] | (.matrix|length)==0 and (.unmeasured|length)==0' 'no changed paths produces measured empty matrix'
[ "$(bash "$RADAR" app)" = 'app: no overlap' ] || fail 'no overlap output'
pass 'human no overlap output'

printf 'alpha\n' > "$TMP_ROOT/alpha/alpha-only.sh"
printf 'beta\n' > "$TMP_ROOT/beta/beta-only.sh"
run_radar
assert_json '.projects[0].matrix | length==2 and all(.shared|not)' 'two ships with disjoint changed paths have no overlap'
rm "$TMP_ROOT/alpha/alpha-only.sh" "$TMP_ROOT/beta/beta-only.sh"

for worker in alpha beta; do
  printf '%s committed\n' "$worker" >> "$TMP_ROOT/$worker/README.md"
  git -C "$TMP_ROOT/$worker" add README.md
  git -C "$TMP_ROOT/$worker" commit -qm ledger
  printf '%s staged\n' "$worker" >> "$TMP_ROOT/$worker/package.json"
  git -C "$TMP_ROOT/$worker" add package.json
  printf '%s unstaged\n' "$worker" >> "$TMP_ROOT/$worker/code.sh"
  printf '%s untracked\n' "$worker" > "$TMP_ROOT/$worker/new file.txt"
  printf '%s custom ledger\n' "$worker" >> "$TMP_ROOT/$worker/golden/questions.json"
done
index_before=$(git -C "$TMP_ROOT/alpha" hash-object .git/index)
run_radar
assert_json '.projects[0].matrix | any(.path=="README.md" and .class=="ledger" and .shared)' 'committed shared ledger path'
assert_json '.projects[0].matrix | any(.path=="package.json" and .class=="mechanical" and .shared)' 'staged shared mechanical path'
assert_json '.projects[0].matrix | any(.path=="code.sh" and .class=="code" and .shared)' 'unstaged shared code path'
assert_json '.projects[0].matrix | any(.path=="new file.txt" and .class=="ledger" and .shared)' 'untracked spaced path stays intact'
assert_json '.projects[0].matrix | any(.path=="golden/questions.json" and .class=="ledger" and .shared)' 'explicit JSON ledger overrides code classification'
[ "$index_before" = "$(git -C "$TMP_ROOT/alpha" hash-object .git/index)" ] || fail 'radar changed worktree index'
pass 'radar does not refresh index'
bash "$RADAR" --json > "$TMP_ROOT/auto.json"
jq -e '.projects|length==1' "$TMP_ROOT/auto.json" >/dev/null || fail 'automatic project selection'
bash "$RADAR" --toon app | rg -q '^  "app","mechanical","package.json"' || fail 'TOON shared paths'
pass 'automatic selection and TOON output'

cp "$FM_STATE_OVERRIDE/beta.meta" "$TMP_ROOT/beta.meta"
sed 's|worktree=.*|worktree=/nonexistent/fixture|' "$TMP_ROOT/beta.meta" > "$FM_STATE_OVERRIDE/beta.meta"
run_radar
assert_json '.projects[0] | any(.sources[]; .task_id=="beta" and .measurement=="unmeasured" and (.paths|index("code.sh"))!=null) and (.unmeasured|length)>0' 'unreadable worktree retains earlier observed paths'
cp "$TMP_ROOT/beta.meta" "$FM_STATE_OVERRIDE/beta.meta"
sed 's|worktree=.*|worktree=|' "$TMP_ROOT/beta.meta" > "$FM_STATE_OVERRIDE/beta.meta"
run_radar
assert_json '.projects[0] | any(.sources[]; .task_id=="beta" and .measurement=="unmeasured")' 'empty worktree cannot read the radar caller checkout'
cp "$TMP_ROOT/beta.meta" "$FM_STATE_OVERRIDE/beta.meta"
git -C "$TMP_ROOT/beta" restore --staged --worktree code.sh package.json golden/questions.json
rm "$TMP_ROOT/beta/new file.txt"
run_radar
assert_json '.projects[0].matrix | any(.path=="code.sh" and (.shared|not))' 'fresh measurement replaces prior reverted paths'

printf '[{"number":7,"html_url":"https://github.com/fixture/app/pull/7","head":{"ref":"ship/alpha"}}]\n' > "$RADAR_FIXTURE/prs.json"
printf '[{"filename":"README.md"},{"filename":"pr-only.md"}]\n' > "$RADAR_FIXTURE/files.json"
run_radar
assert_json '.projects[0].matrix | any(.path=="README.md" and (.sources|length)==3 and (.participants|length)==2)' 'task and its PR count as one participant'
assert_json '.projects[0].matrix | any(.path=="pr-only.md" and (.shared|not))' 'PR-only path is observed'
touch "$RADAR_FIXTURE/files-fail"
run_radar
assert_json '.projects[0] | any(.sources[]; .kind=="pr" and .measurement=="unmeasured" and (.paths|index("pr-only.md"))!=null) and (.unmeasured|length)>0' 'failed PR file read retains prior matrix evidence'
rm "$RADAR_FIXTURE/files-fail"
touch "$RADAR_FIXTURE/pages"
jq -n '[range(100)|{filename:("path-"+(.|tostring)+".md")}]' > "$RADAR_FIXTURE/files-page1.json"
printf '[{"filename":"page-two.md","previous_filename":"renamed-page.md"}]\n' > "$RADAR_FIXTURE/files-page2.json"
run_radar
assert_json '.projects[0].sources | any(.kind=="pr" and (.paths|length)==102 and (.paths|index("page-two.md"))!=null and (.paths|index("renamed-page.md"))!=null)' 'GitHub changed-file pagination includes rename source and second page'
rm "$RADAR_FIXTURE/pages"
run_radar
printf '[]\n' > "$RADAR_FIXTURE/prs.json"
printf '{"state":"closed"}\n' > "$RADAR_FIXTURE/state.json"
run_radar
assert_json '.projects[0].sources | any(.kind=="pr" and .status=="closed" and (.paths|index("pr-only.md"))!=null)' 'completed PR remains until associated task teardown'
rm "$FM_STATE_OVERRIDE/alpha.meta"
run_radar
assert_json '.projects[0].sources | all(.kind!="pr" and .task_id!="alpha")' 'gone task and completed PR evidence is pruned'

touch "$RADAR_FIXTURE/fail"
run_radar
assert_json '.projects[0].unmeasured | any(startswith("forge:"))' 'forge failure is explicitly unmeasured'
output=$(bash "$RADAR" app)
[[ "$output" != *'no overlap'* ]] || fail 'forge failure claimed no overlap'
pass 'failed forge never claims no overlap'
rm "$RADAR_FIXTURE/fail"

printf 'kind=scout\nproject=%s\nworktree=/missing\n' "$PROJECT_FIXTURE" > "$FM_STATE_OVERRIDE/scout.meta"
bash "$RADAR" --json > "$TMP_ROOT/auto.json"
jq -e '.projects|length==0' "$TMP_ROOT/auto.json" >/dev/null || fail 'scout counted as ship'
pass 'automatic selection excludes scouts and single-ship projects'

printf 'base_branch=main\n' >> "$FM_STATE_OVERRIDE/beta.meta"
git -C "$TMP_ROOT/beta" symbolic-ref --delete refs/remotes/origin/HEAD
run_radar
assert_json '.projects[0].sources | any(.task_id=="beta" and .measurement=="measured")' 'explicit task base works without origin HEAD'

cat > "$TOOLS/az" <<'EOF'
#!/usr/bin/env bash
printf 'fixture-token\n'
EOF
cat > "$TOOLS/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$RADAR_CALLS"
case "$*" in *fixture-token*) exit 1 ;; esac
authorization=$(cat <&3)
[ "$authorization" = 'Authorization: Bearer fixture-token' ] || exit 1
for url in "$@"; do :; done
case "$url" in
  */pullRequests\?*) cat "$RADAR_FIXTURE/ado-prs.json" ;;
  */iterations\?*) printf '{"value":[{"id":1},{"id":3},{"id":2}]}\n' ;;
  */iterations/3/changes\?*compareTo=0*\$skip=0*)
    printf '{"changeEntries":[{"item":{"path":"/README.md"}},{"item":{"path":"/folder","isFolder":true}}],"nextSkip":1,"nextTop":1}\n' ;;
  */iterations/3/changes\?*compareTo=0*\$skip=1*)
    printf '{"changeEntries":[{"item":{"path":"/Directory.Packages.props"},"originalPath":"/old.props"}],"nextSkip":0,"nextTop":0}\n' ;;
  */pullRequests/7\?*) printf '{"status":"completed"}\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TOOLS/az" "$TOOLS/curl"
printf '{"value":[{"pullRequestId":7,"repository":{"webUrl":"https://dev.azure.com/fixture/project/_git/app"},"sourceRefName":"refs/heads/ship/beta"}]}\n' > "$RADAR_FIXTURE/ado-prs.json"
git -C "$TMP_ROOT/beta" remote set-url origin git@ssh.dev.azure.com:v3/fixture/project/app
rm "$FM_STATE_OVERRIDE/conflict-radar/app.json"
run_radar
assert_json '.projects[0] | (.unmeasured|length)==0 and any(.sources[]; .kind=="pr" and (.paths|length)==3 and (.paths|index("Directory.Packages.props"))!=null and (.paths|index("old.props"))!=null)' 'Azure latest iteration compares to base and follows both change pages'
assert_json '.projects[0].matrix | any(.path=="Directory.Packages.props" and .class=="mechanical")' 'Azure paths normalize leading slash and classify package props'
assert_json '.projects[0].matrix | any(.path=="README.md" and (.shared|not) and (.sources|length)==2)' 'Azure PR and its own task are not false overlap'
git -C "$TMP_ROOT/beta" remote set-url origin https://fixture@dev.azure.com/fixture/project/_git/app
run_radar
assert_json '.projects[0].unmeasured|length==0' 'Azure HTTPS clone userinfo is normalized without exposing credentials'
printf '{"value":[]}\n' > "$RADAR_FIXTURE/ado-prs.json"
run_radar
assert_json '.projects[0].sources | any(.kind=="pr" and .status=="completed")' 'Azure completed PR retains paths until teardown'

REAL_GIT=$(command -v git)
export REAL_GIT
cat > "$TOOLS/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in *symbolic-ref*) sleep 30 ;; *) exec "$REAL_GIT" "$@" ;; esac
EOF
chmod +x "$TOOLS/git"
sed '/^base_branch=/d' "$FM_STATE_OVERRIDE/beta.meta" > "$TMP_ROOT/meta.next"
mv "$TMP_ROOT/meta.next" "$FM_STATE_OVERRIDE/beta.meta"
FM_CONFLICT_RADAR_TIMEOUT=1 run_radar
assert_json '.projects[0].sources | any(.kind=="task" and .measurement=="unmeasured")' 'Git timeout is bounded and reported as unmeasured'
rm "$TOOLS/git"

rm "$FM_STATE_OVERRIDE/beta.meta"
run_radar
assert_json '.projects[0] | (.sources|length)==0 and (.unmeasured|length)==0' 'last teardown prunes completed PR using remembered project path'

printf 'invalid\n' > "$FM_STATE_OVERRIDE/conflict-radar/app.json"
if bash "$RADAR" --json app >/dev/null 2>&1; then fail 'corrupt memory accepted'; fi
pass 'corrupt memory refuses rather than silently erasing evidence'
