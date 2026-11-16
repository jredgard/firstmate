#!/usr/bin/env bash
# Usage: drive-teardown.sh <lab> <scripts-root> <task-id> <pr-url> <pr-head|LOCAL> 
# Sets up one ship task in the lab home (worktree of the cloned project at
# PR 14's recorded head), then runs the real bin/fm-teardown.sh with the real
# gh-axi on PATH. Only tmux/treehouse/no-mistakes are stubbed (logged).
set -u
LAB=$1 ROOT=$2 ID=$3 PR=$4 HEAD=$5
PROJ=$LAB/projects/no-mistakes WTD=$LAB/wt/$ID
if [ ! -d "$WTD" ]; then
  git -C "$PROJ" worktree add -q -b "fm/$ID" "$WTD" 211d49ac7afaa99f71bee5de0a143825540b8326
fi
if [ "$HEAD" = LOCAL ]; then
  git -C "$WTD" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m "lab: unlanded local commit"
  HEAD=$(git -C "$WTD" rev-parse HEAD)
fi
[ -f "$LAB/data/backlog.md" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi show "$ID" --file "$LAB/data/backlog.md" >/dev/null 2>&1 || {
  tasks-axi add "$ID" "lab teardown $ID" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$LAB/data/backlog.md" >/dev/null; }
printf '%s\n' "window=fm-lab:fm-$ID" "endpoint_task_id=$ID" "worktree=$WTD" "project=$PROJ" \
  kind=ship "branch=fm/$ID" mode=no-mistakes "spawn_gen=lab-$ID" "pr=$PR" "pr_head=$HEAD" > "$LAB/state/$ID.meta"
touch "$LAB/state/.last-watcher-beat"
echo "\$ gh-axi --version: $(gh-axi --version)"
echo "\$ (scripts: $ROOT) fm-teardown.sh $ID   # pr=$PR pr_head=$HEAD"
rc=0
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" PATH="$LAB/stub:$PATH" "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1 || rc=$?
echo "exit=$rc"
echo "meta present after: $([ -f "$LAB/state/$ID.meta" ] && echo yes || echo no)"
echo "backlog state after: $(tasks-axi show "$ID" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)"
