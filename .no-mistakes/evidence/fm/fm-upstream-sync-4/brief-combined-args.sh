#!/usr/bin/env bash
# Drive bin/fm-brief.sh in a marked lab home with the fork --nm-skip and upstream --base-branch flags.
set -u
LAB=$1
run() { echo "\$ FM_HOME=\$LAB bin/fm-brief.sh $*"; env -u NO_MISTAKES_GATE FM_HOME="$LAB" bin/fm-brief.sh "$@"; echo "exit=$?"; echo; }
run t-merge1b demo --mode no-mistakes --nm-skip lint --base-branch develop
run t2 demo --mode direct-PR --nm-skip lint --base-branch develop
run t3 demo --mode no-mistakes --nm-skip review --base-branch develop
run t4 demo --mode no-mistakes --nm-skip lint --base-branch ../evil
run t5 demo --scout --nm-skip lint
run t6 demo --mode no-mistakes --nm-skip lint
run t7 demo --mode no-mistakes --base-branch release/1.2
for t in t-merge1b t6 t7; do echo "== $t rendered delivery lines"; grep -nE 'Base branch:|Delivery contract|--base-branch|--skip lint' "$LAB/data/$t/brief.md" 2>&1 | head -6; done
