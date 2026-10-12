#!/usr/bin/env bash
# Live: session-start consumer `fm-contributions.sh arm --if-owned` (called by
# fm-bootstrap.sh) on a lab home whose backlog owns PR URLs and exceeds 128 KiB.
set -u
WT=$1; ROWS=${2:-80}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-live.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/base"; git -C "$WT" archive d9da4de bin | tar -x -C "$WORK/base"
for label in base fix; do
  bin="$WT/bin"; [ "$label" = base ] && bin="$WORK/base/bin"
  LAB="$WORK/lab-$label"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  { printf '# Backlog\n\n## Queued\n'
    for ((i = 1; i <= ROWS; i++)); do
      printf -- '- [ ] mosaiq-%s - Mosaiq queued item %s https://github.com/o/r/pull/%s (repo: mosaiq) (kind: ship)\n' "$i" "$i" "$i"
      printf '  Detail: %s\n' "$(head -c 2000 /dev/zero | tr '\0' 'x')"
    done; } > "$LAB/data/backlog.md"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$WORK" bash "$bin/fm-contributions.sh" arm --if-owned > "$WORK/$label.out" 2>&1
  rc=$?
  echo "=== $label: fm-contributions.sh arm --if-owned exit=$rc ($(grep -c '^- \[ \]' "$LAB/data/backlog.md") queued rows owning PR URLs)"
  sed 's/^/  output: /' "$WORK/$label.out" | head -5
  if [ -f "$LAB/state/contributions.check.sh" ]; then
    echo "  contributions watcher check ARMED: state/contributions.check.sh present, trust=$( [ -f "$LAB/state/contributions.check-trust" ] && echo yes || echo no)"
  else
    echo "  contributions watcher check NOT armed (state/contributions.check.sh absent)"
  fi
done
