#!/usr/bin/env bash
# new-case.sh <task-id> <state-json-file>: fresh task meta + emulator state
set -eu
LAB=/tmp/fm-lab.V0GmFX
id=$1
cp "$2" "$LAB/state.json"
rm -rf "$LAB/wt-$id"; mkdir -p "$LAB/wt-$id"
git -C "$LAB/wt-$id" init -q -b feature
git -C "$LAB/wt-$id" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m lab
git -C "$LAB/wt-$id" update-ref refs/remotes/origin/main HEAD
[ -f "$LAB/home/.tasks.toml" ] || cp /home/johannesr/.no-mistakes/worktrees/551ff26a6b1c/01M443Y636779T2GZQNWYHNYJJ/.tasks.toml "$LAB/home/.tasks.toml"
[ -f "$LAB/home/data/backlog.md" ] || printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/home/data/backlog.md"
rm -f "$LAB/home/state/$id".*
printf '%s\n' "window=fm-$id" "worktree=$LAB/wt-$id" "project=$LAB/project" kind=ship mode=no-mistakes > "$LAB/home/state/$id.meta"
