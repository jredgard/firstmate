#!/usr/bin/env bash
# Live drive of bin/fm-conflict-radar.sh against a disposable lab FM_HOME:
# real shallow clone of github.com/jredgard/firstmate, two real git worktrees
# as ship tasks, real gh-axi reads of the repo's actual open PRs.
set -u
RADAR_REPO=$1 LAB=$2
RADAR="$RADAR_REPO/bin/fm-conflict-radar.sh"
P="$LAB/projects/firstmate"
run() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"

echo "### S0 setup: registry with ledgers= token, two ship worktrees"
printf '%s\n' '- firstmate [no-mistakes ledgers=docs/verification/conflict-radar.md,docs/scripts.md] - lab fixture' > "$LAB/data/projects.md"
for w in alpha beta; do
  git -C "$P" worktree add -q "$LAB/worktrees/$w" -b "ship/$w"
  git -C "$LAB/worktrees/$w" config user.email lab@example.com; git -C "$LAB/worktrees/$w" config user.name Lab
  printf 'project=%s\nworktree=%s\nkind=ship\nbranch=ship/%s\n' "$P" "$LAB/worktrees/$w" "$w" > "$LAB/state/$w.meta"
done
run bash "$RADAR_REPO/bin/fm-project-mode.sh" --ledgers firstmate
run bash "$RADAR_REPO/bin/fm-project-mode.sh" firstmate

echo; echo "### S1 two ships, no edits yet; real open PRs #21/#23 overlap each other only (external-only)"
run bash "$RADAR" firstmate
bash "$RADAR" --json firstmate > "$LAB/s1.json"
jq '.projects[0] | {unmeasured, prs:[.sources[]|select(.kind=="pr")|{id,task_ids,n:(.paths|length),measurement}], external_overlaps:[.matrix[]|select((.participants|length)>1)|{path,class,participants,shared}]}' "$LAB/s1.json"

echo; echo "### S2 concurrent wave edits (committed, staged, unstaged, untracked) across classes"
A="$LAB/worktrees/alpha" B="$LAB/worktrees/beta"
snap() { for w in "$P" "$A" "$B"; do git -C "$w" for-each-ref --format='%(refname) %(objectname)'; git -C "$w" status --porcelain=v1 -uall; git -C "$w" rev-parse HEAD; done; sha256sum "$P/.git/index" "$P/.git/worktrees/"*/index; }
for w in "$A" "$B"; do
  n=$(basename "$w")
  printf '\n%s wave note\n' "$n" >> "$w/README.md"
  printf '\n%s ledger\n' "$n" >> "$w/docs/verification/conflict-radar.md" 2>/dev/null || printf '%s\n' "$n" > "$w/docs/verification/conflict-radar.md"
  printf 'requests==2.%s\n' "$n" > "$w/requirements.txt"
  git -C "$w" add README.md requirements.txt docs/verification/conflict-radar.md; git -C "$w" commit -qm "$n wave"
  printf 'cmake_minimum_required(VERSION 3.%s)\n' "${#n}" > "$w/CMakeLists.txt"; git -C "$w" add CMakeLists.txt
  printf '\n# %s\n' "$n" >> "$w/bin/fm-spawn.sh"
  printf '%s notes\n' "$n" > "$w/NOTES.txt"
  printf '{"%s":1}\n' "$n" > "$w/package-lock.json"
done
printf '\n# alpha touches a path real PR #21 and #23 also touch\n' >> "$A/tests/fm-calm-pi-extension.test.sh"
printf '%s\n' alpha-only > "$A/alpha-only.sh"
snap > "$LAB/before.snap"
run bash "$RADAR" firstmate
bash "$RADAR" --json firstmate > "$LAB/s2.json"
jq '.projects[0] | {ledgers, unmeasured, shared:[.matrix[]|select(.shared)|{path,class,participants}], not_shared:[.matrix[]|select(.shared|not)|{path,class,participants}]}' "$LAB/s2.json"
snap > "$LAB/after.snap"
echo; echo "--- read-only check: refs, HEADs, status and index hashes before vs after radar runs"
if diff "$LAB/before.snap" "$LAB/after.snap"; then echo "IDENTICAL (radar wrote nothing into the project or its worktrees)"; fi
echo "--- radar memory files under lab state:"; find "$LAB/state/conflict-radar" -type f
echo "--- untracked/ignored files in project checkout:"; git -C "$P" status --porcelain=v1 --ignored -uall | head
jq '{schema_version,project,project_path,timestamp,ledgers,n_sources:(.sources|length),n_matrix:(.matrix|length)}' "$LAB/state/conflict-radar/firstmate.json"

echo; echo "### S3 unreadable worktree retains remembered paths and never claims no overlap"
mv "$B" "$B.moved"
run bash "$RADAR" firstmate
bash "$RADAR" --json firstmate | jq '.projects[0].sources[]|select(.task_id=="beta")|{id,measurement,observed_at,paths}'
mv "$B.moved" "$B"

echo; echo "### S4 later worker steered: beta drops redundant ledger edit -> fresh measurement replaces memory"
git -C "$B" reset -q --hard HEAD~1; git -C "$B" clean -qfd
printf '\n# beta\n' >> "$B/bin/fm-spawn.sh"
run bash "$RADAR" firstmate

echo; echo "### S5 task teardown prunes its memory; single remaining ship"
rm "$LAB/state/beta.meta"
run bash "$RADAR"
run bash "$RADAR" firstmate
jq '[.sources[]|{id,kind}]' "$LAB/state/conflict-radar/firstmate.json"

echo; echo "### S6 forge unreadable (origin repo does not exist) is unmeasured, never 'no overlap'"
printf 'project=%s\nworktree=%s\nkind=ship\nbranch=ship/beta\n' "$P" "$B" > "$LAB/state/beta.meta"
git -C "$B" checkout -q -- bin/fm-spawn.sh; git -C "$A" reset -q --hard origin/HEAD; git -C "$A" clean -qfd
git -C "$P" remote set-url origin https://github.com/jredgard/no-such-repo-fm-lab-xyz.git
run bash "$RADAR" firstmate
git -C "$P" remote set-url origin https://github.com/jredgard/firstmate.git
run bash "$RADAR" firstmate

echo; echo "### S7 corrupt memory is refused, not silently overwritten"
printf 'garbage\n' > "$LAB/state/conflict-radar/firstmate.json"
run bash "$RADAR" firstmate
cat "$LAB/state/conflict-radar/firstmate.json"
