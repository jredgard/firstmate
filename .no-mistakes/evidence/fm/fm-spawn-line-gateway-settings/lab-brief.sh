#!/usr/bin/env bash
# lab-brief.sh <id> ship|scout : scaffold a filled brief and backlog item.
. /home/johannesr/.no-mistakes/evidence/01M419TAC0NVR31GRTV07N4E09/lab.env
R=/home/johannesr/.no-mistakes/evidence/01M419TAC0NVR31GRTV07N4E09/lab-run.sh
id=$1 kind=$2
if [ "$kind" = scout ]; then "$R" "$LAB/bin/fm-brief.sh" "$id" notes --scout >/dev/null || exit 1
else "$R" "$LAB/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null || exit 1; fi
TASK_TEXT="Gateway live-validation probe. Reply with one short sentence and stop. Do not edit files." \
SPEC_TEXT="Reply once, append nothing, and end your turn. Nothing else is in scope." \
python3 - "$LAB/data/$id/brief.md" <<'PY'
import os, sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"], 1)
open(p, "w").write(t)
PY
"$R" "$LAB/bin/fm-tasks-axi.sh" add "$id" "gateway probe $id" --kind "$kind" --repo notes >/dev/null
