#!/usr/bin/env bash
# usage: sweep.sh <label>  - run one real watcher cycle in the lab, print outcome, then ack wakes
. "/tmp/fm-lab.OwC8U9/env.sh"
label=$1; ST=$FM_HOME/state
rm -f "$ST/.last-check"
echo "=== sweep: $label   (server: 42=$(cat /tmp/fm-lab.OwC8U9/srvstate/42.state 2>/dev/null) 43=$(cat /tmp/fm-lab.OwC8U9/srvstate/43.state 2>/dev/null))"
before=$(wc -l < /tmp/fm-lab.OwC8U9/server.log)
rc=0
timeout -k 2 ${SWEEP_TIMEOUT:-8} env FM_CHECK_INTERVAL=0 FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "/home/johannesr/.no-mistakes/worktrees/e0341a3b611a/01M4R06KX81W5DQJ44AFV5W8TB/bin/fm-watch.sh" > /tmp/fm-lab.OwC8U9/watch.out 2> /tmp/fm-lab.OwC8U9/watch.err || rc=$?
echo "watcher rc=$rc  (124 = no wake within bound, i.e. silent)"
echo "ADO GETs this sweep: $(( $(wc -l < /tmp/fm-lab.OwC8U9/server.log) - before ))"
echo "--- watcher stdout:"; sed 's/^/  /' /tmp/fm-lab.OwC8U9/watch.out
[ ! -s /tmp/fm-lab.OwC8U9/watch.err ] || { echo "--- watcher stderr (tail):"; tail -5 /tmp/fm-lab.OwC8U9/watch.err | sed 's/^/  /'; }
echo "--- marker task-a.pr-poll-last-reported: $( [ -e $ST/task-a.pr-poll-last-reported ] && { stat -c 'mode=%a' $ST/task-a.pr-poll-last-reported; tr '\n' '|' < $ST/task-a.pr-poll-last-reported; } || echo absent)"
echo "--- armed polls: $(cd $ST && ls *.check.sh 2>/dev/null | tr '\n' ' ')"
if [ -s "$ST/.wake-queue" ]; then echo "--- durable wake queue:"; sed 's/^/  /' "$ST/.wake-queue"; fi
if [ "${NO_ACK:-0}" != 1 ]; then
  err=$(FM_STATE_OVERRIDE= "/home/johannesr/.no-mistakes/worktrees/e0341a3b611a/01M4R06KX81W5DQJ44AFV5W8TB/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \(.*\)$/\1/p')
  gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \(.*\)$/\1/p')
  if [ -n "$seq" ]; then "/home/johannesr/.no-mistakes/worktrees/e0341a3b611a/01M4R06KX81W5DQJ44AFV5W8TB/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && echo "(acked wakes through $seq)"; fi
fi
echo
