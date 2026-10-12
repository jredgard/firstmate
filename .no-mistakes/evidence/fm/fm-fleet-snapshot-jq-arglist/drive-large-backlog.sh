#!/usr/bin/env bash
# Live repro: --contribution-input on a disposable lab home whose backlog JSON
# exceeds Linux MAX_ARG_STRLEN (128 KiB per single argv string), base vs fix,
# with the real /usr/bin/jq (no stand-in).
set -u
WT=$1; ROWS=${2:-80}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-argv-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/base"
git -C "$WT" archive d9da4de bin | tar -x -C "$WORK/base"
LAB="$WORK/lab"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
{
  printf '# Backlog\n\n## Queued\n'
  for ((i = 1; i <= ROWS; i++)); do
    printf -- '- [ ] mosaiq-%s - Mosaiq queued item %s https://github.com/o/r/pull/%s (repo: mosaiq) (kind: ship)\n' "$i" "$i" "$i"
    printf '  Detail: %s\n' "$(head -c 2000 /dev/zero | tr '\0' 'x')"
  done
} > "$LAB/data/backlog.md"
for i in 1 2 3; do
  printf 'kind=ship\nyolo=off\npr=https://github.com/o/r/pull/90%s\n' "$i" > "$LAB/state/ship-$i.meta"
done
echo "jq: $(command -v jq) ($(jq --version)); getconf ARG_MAX=$(getconf ARG_MAX)"
echo "backlog.md: $(grep -c '^- \[ \]' "$LAB/data/backlog.md") queued rows, $(wc -c < "$LAB/data/backlog.md") bytes"
run() { # label bindir
  local label=$1 bin=$2 rc tmpd
  tmpd="$WORK/tmp-$label"; mkdir -p "$tmpd"
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$tmpd" FM_SNAPSHOT_NOW=2026-10-12T12:00:00Z \
    bash "$bin/fm-fleet-snapshot.sh" --contribution-input > "$WORK/$label.json" 2> "$WORK/$label.err"
  rc=$?
  echo "=== $label: fm-fleet-snapshot.sh --contribution-input exit=$rc"
  sed 's/^/  stderr: /' "$WORK/$label.err" | head -5
  if [ "$rc" -eq 0 ]; then
    jq -r '"  stdout: backlog.present=\(.backlog.present) backlog.records=\(.backlog.records|length) backlog_json_bytes=\(.backlog|tojson|length) tasks=\(.tasks|length) task_ids=\([.tasks[].id]|sort|join(","))"' "$WORK/$label.json"
  fi
  echo "  leftover temp entries under TMPDIR: $(find "$tmpd" -mindepth 1 | wc -l)"
}
run base "$WORK/base/bin"
run fix "$WT/bin"
# Full snapshot (default --json path) must still assemble with the moved transport dir.
mkdir -p "$WORK/tmp-json"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMPDIR="$WORK/tmp-json" FM_SNAPSHOT_NOW=2026-10-12T12:00:00Z \
  bash "$WT/bin/fm-fleet-snapshot.sh" --json > "$WORK/full.json" 2> "$WORK/full.err"
echo "=== fix: fm-fleet-snapshot.sh --json exit=$?"
sed 's/^/  stderr: /' "$WORK/full.err" | head -5
jq -r '"  stdout: backlog.records=\(.backlog.records|length) tasks=\(.tasks|length) contributions.known=\(.contributions.known // "n/a")"' "$WORK/full.json" 2>&1
echo "  leftover temp entries under TMPDIR: $(find "$WORK/tmp-json" -mindepth 1 | wc -l)"
# Session-start consumer: fm-bootstrap runs `fm-contributions.sh pending`-free arm --if-owned -> get_input.
for label in base fix; do
  bin="$WT/bin"; [ "$label" = base ] && bin="$WORK/base/bin"
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$WORK" FM_SNAPSHOT_NOW=2026-10-12T12:00:00Z \
    bash -c 'f=$(mktemp); "$1/fm-fleet-snapshot.sh" --contribution-input > "$f" && FM_CONTRIBUTIONS_NOW=2026-10-12T12:00:00Z "$1/fm-contributions.sh" snapshot "$f"; echo "rc=$?"; rm -f "$f"' _ "$bin" 2>&1)
  echo "=== $label: --contribution-input | fm-contributions.sh snapshot"
  printf '%s\n' "$out" | jq -rR 'fromjson? // . ' 2>/dev/null | jq -rR '.' | sed 's/^/  /' | head -6
done
