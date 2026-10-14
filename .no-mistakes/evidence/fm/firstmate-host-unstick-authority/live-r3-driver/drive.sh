#!/usr/bin/env bash
# Live driver: real fm-supervision-host.sh + real Claude engine in a disposable lab home.
# usage: drive.sh <scenario> <words> <evidence-dir>
set -u
WT=${DRIVE_WT:-/home/johannesr/.no-mistakes/worktrees/e0341a3b611a/01M4XYZWBD2J0EX4BYNE5XHFVT}
SC=$1 WORDS=$2 EV=$3
SCR=$(mktemp -d /tmp/fm-livescr.XXXXXX)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$SCR/fakebin" "$SCR/parent"; ln -s "$WT/bin" "$LAB/bin"
: > "$LAB/config/supervision-host"
for t in tmux herdr az gh kubectl; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> %q\nexit 1\n' "$SCR/external-calls.log" > "$SCR/fakebin/$t"
done
cat > "$SCR/fakebin/no-mistakes" <<NM
#!/usr/bin/env bash
printf 'no-mistakes %s\n' "\$*" >> "$SCR/external-calls.log"
f="$SCR/nm-\$(printf '%s' "\$*" | tr -c 'A-Za-z0-9' '_').out"
[ -f "\$f" ] || f="$SCR/nm-default.out"
[ -f "\$f" ] && { cat "\$f"; exit 0; }
echo "error: no-mistakes daemon fixture has no answer for: \$*" >&2; exit 1
NM
chmod +x "$SCR/fakebin"/*
ln -s /bin/bash "$SCR/parent/claude"
ST="$LAB/state"
WTD="$LAB/projects/demo-wt"
mkdir -p "$WTD"
printf 'project=demo\nwindow=fm-demo\nharness=claude\nkind=ship\nworktree=%s\nbranch=fm/demo\n' "$WTD" > "$ST/demo.meta"
. /tmp/fm-live-drv/scenario-"$SC".sh   # defines setup() and trigger()
setup
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM \
  FM_HOME="$LAB" "$WT/bin/fm-afk-contract.sh" enter --words "$WORDS" > "$SCR/contract.out" 2>&1 || { echo contract failed; cat "$SCR/contract.out"; exit 1; }
( cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM \
  FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" PATH="$SCR/fakebin:$PATH" FM_SUPERVISION_HOST_PRIMARY=claude \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$SCR/parent/claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$0" park > "$FM_HOME/../$(basename "$FM_HOME").host.out" 2>&1; printf "%s\n" "$?" > "$FM_HOME/../$(basename "$FM_HOME").host.rc"' "$WT/bin/fm-supervision-host.sh" ) 2> "$SCR/parent.err" &
OUT="$(dirname "$LAB")/$(basename "$LAB").host.out" RC="$(dirname "$LAB")/$(basename "$LAB").host.rc"
i=0; until pid=$(cat "$ST/.watch.lock/pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null; do i=$((i+1)); [ $i -lt 600 ] || { echo watcher never live; cat "$OUT" "$SCR/parent.err" "$ST/.supervision-host.log" 2>/dev/null; break; }; sleep 0.1; done
start=$(date +%s)
trigger
i=0; while [ $i -lt 480 ]; do
  [ -s "$RC" ] && break
  grep -q '	handled	\|	failed	' "$ST/.supervision-host.log" 2>/dev/null && { sleep 3; break; }
  sleep 1; i=$((i+1))
done
L="$EV/live-r3-$SC.log"
{
  echo "=== scenario: $SC   away words: $WORDS   elapsed: $(( $(date +%s) - start ))s"
  echo "=== host.rc: $(cat "$RC" 2>/dev/null || echo '(host still parked - no exit to MAIN)')"
  echo "=== host.out"; cat "$OUT" 2>/dev/null
  echo "=== supervision-host.log"; cat "$ST/.supervision-host.log" 2>/dev/null
  echo "=== branch-outcomes.jsonl"; cat "$ST/branch-outcomes.jsonl" 2>/dev/null
  echo "=== worker inbox"; for m in "$ST"/*.inbox/*.msg; do [ -f "$m" ] && { echo "--- $m"; cat "$m"; echo; }; done
  echo "=== wake-queue handback rows"; grep 'supervision-host-handback' "$ST/.wake-queue" 2>/dev/null || echo '(none)'
  echo "=== demo.meta present: $([ -e "$ST/demo.meta" ] && echo yes || echo no)"
  echo "=== demo.status tail"; tail -5 "$ST/demo.status" 2>/dev/null
  echo "=== external CLI calls by the engine (fakes)"; cat "$SCR/external-calls.log" 2>/dev/null || echo '(none)'
  echo "=== engine-facing drain (OPEN DECISIONS after turn)"; (cd "$WT" && env -u FM_GATE_REFUSE_BYPASS -u FM_TEST_SEAM FM_HOME="$LAB" PATH="$SCR/fakebin:$PATH" "$WT/bin/fm-wake-drain.sh" 2>&1 | grep -A6 'OPEN DECISIONS' || echo '(no OPEN DECISIONS section)')
} > "$L" 2>&1
# engine transcript: commands
slug=$(printf '%s' "$WT" | sed 's|[^A-Za-z0-9]|-|g')
tr=$(ls -t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | grep -v acaae07d-0587-487b-aa2b-c79af6e5232c | head -1)
if [ -n "$tr" ] && grep -q "$LAB" "$tr"; then
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | (.input.command // (.input|tostring))' "$tr" > "$EV/live-r3-$SC.engine-commands.txt" 2>/dev/null
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$tr" | tail -40 > "$EV/live-r3-$SC.engine-final.txt" 2>/dev/null
fi
cp "$ST/.supervision-host-prompt" "$EV/live-r3-$SC.system-prompt.txt" 2>/dev/null
# teardown
hp=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$ST/.supervision-host" 2>/dev/null)
[ -z "$hp" ] || kill -TERM "$hp" 2>/dev/null
for a in $(awk -F '\t' '$1 == "arm" { print $2 }' "$ST/.supervision-host" 2>/dev/null); do kill -TERM "$a" 2>/dev/null; done
wp=$(cat "$ST/.watch.lock/pid" 2>/dev/null); [ -z "$wp" ] || kill -TERM "$wp" 2>/dev/null
sleep 2
pkill -TERM -f "$LAB" 2>/dev/null
sleep 1
rm -rf "$LAB" "$OUT" "$RC" "$SCR"
echo "done: $L"
