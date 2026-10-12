#!/usr/bin/env bash
# Live drive: fm-fleet-snapshot.sh --contribution-input on a Mosaiq-sized backlog,
# base commit (d9da4de) vs fixed commit (worktree HEAD), in a disposable lab home.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
H=$LAB/home
mkdir -p "$LAB/base" "$LAB/tmp"
git -C "$WT" archive d9da4de | tar -x -C "$LAB/base"
echo "kernel ARG_MAX=$(getconf ARG_MAX); MAX_ARG_STRLEN (single arg) = 131072"
{
  printf '## Queued\n'
  for i in $(seq 1 60); do
    printf -- '- [ ] mosaiq-item-%s - Mosaiq queued work item %s (repo: alpha) (kind: ship)\n' "$i" "$i"
    printf '  Detail: %s\n' "$(head -c 2400 /dev/zero | tr '\0' 'x')"
  done
} > "$H/data/backlog.md"
for i in $(seq 1 3); do
  printf 'kind=ship\nyolo=off\npr=https://github.com/o/r/pull/%s\n' "$i" > "$H/state/ship-$i.meta"
done
echo "queued rows in backlog.md: $(grep -c '^- \[ \]' "$H/data/backlog.md")"

run() { # label script-root
  local label=$1 root=$2 rc
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$H" TMPDIR="$LAB/tmp" bash "$root/bin/fm-fleet-snapshot.sh" --contribution-input > "$LAB/$label.json" 2> "$LAB/$label.err"
  rc=$?
  echo "--- $label: exit=$rc"
  sed 's/^/    stderr: /' "$LAB/$label.err" | cut -c1-200
  if [ "$rc" -eq 0 ]; then
    jq -r '"    output bytes=\(tojson|length) backlog JSON bytes=\(.backlog|tojson|length) backlog.present=\(.backlog.present) records=\(.backlog.records|length) first=\(.backlog.records[0].id) last=\(.backlog.records[-1].id) tasks=\(.tasks|length)"' "$LAB/$label.json"
  fi
  echo "    leftover transport entries in TMPDIR: $(find "$LAB/tmp" -mindepth 1 | wc -l)"
}
echo "=== S1 base commit d9da4de (before fix)"
run base "$LAB/base"
echo "=== S2 fixed commit (worktree HEAD)"
run fixed "$WT"

echo "=== S3 consumer: fm-contributions.sh poll on the same home (fixed)"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$H" TMPDIR="$LAB/tmp" FM_CONTRIBUTIONS_BUDGET=5 PATH="$LAB/nogh:$PATH" \
  bash "$WT/bin/fm-contributions.sh" poll > "$LAB/poll.out" 2> "$LAB/poll.err"
echo "--- poll exit=$?"; head -c 600 "$LAB/poll.out"; echo; sed 's/^/    stderr: /' "$LAB/poll.err" | cut -c1-200 | head
echo "=== S3b consumer poll on base commit"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$H" TMPDIR="$LAB/tmp" FM_CONTRIBUTIONS_BUDGET=5 \
  bash "$LAB/base/bin/fm-contributions.sh" poll > "$LAB/pollb.out" 2> "$LAB/pollb.err"
echo "--- base poll exit=$?"; head -c 300 "$LAB/pollb.out"; echo; sed 's/^/    stderr: /' "$LAB/pollb.err" | cut -c1-200 | head

echo "=== S4 full snapshot --json (fixed) with same large backlog"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$H" TMPDIR="$LAB/tmp" bash "$WT/bin/fm-fleet-snapshot.sh" --json > "$LAB/full.json" 2> "$LAB/full.err"
echo "--- full exit=$?"; sed 's/^/    stderr: /' "$LAB/full.err" | cut -c1-200 | head -5
jq -r '"    top-level keys=\(keys|join(",")) backlog records=\(.backlog.records|length? // "n/a") contributions present=\(has("contributions"))"' "$LAB/full.json" 2>&1 | head -3
echo "    leftover transport entries in TMPDIR: $(find "$LAB/tmp" -mindepth 1 | wc -l)"
