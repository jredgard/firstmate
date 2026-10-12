#!/usr/bin/env bash
EV=/home/johannesr/.no-mistakes/evidence/01M4RX0RS30YV8EG8FN6X60GBY
LAB=$(cat /tmp/fm-brieflab-path)
for w in background foreground; do
  if [ $w = foreground ]; then touch $LAB/config/wait-no-turns; else rm -f $LAB/config/wait-no-turns; fi
  for k in no-mistakes gerrit gerrit-skip skip direct-PR local-only scout; do
    case $k in scout) a=(--scout);; gerrit) a=(--mode no-mistakes --forge gerrit);; gerrit-skip) a=(--mode no-mistakes --forge gerrit --nm-skip lint);; skip) a=(--mode no-mistakes --nm-skip lint);; *) a=(--mode $k);; esac
    id="live-$w-$k"; rm -rf "$LAB/data/$id"
    env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$LAB bash bin/fm-brief.sh $id some-proj "${a[@]}" >/dev/null 2>$LAB/$id.err; echo "$id rc=$?"
    cp $LAB/data/$id/brief.md $EV/brief-$id.md
  done
done
