#!/usr/bin/env bash
# fm-endpoint-records.sh - read this home's endpoint metadata for JS consumers.
# Usage: bash bin/fm-endpoint-records.sh <state-dir>
# Outputs eight NUL-delimited fields per record: task, meta path, project,
# kind, backend, window, terminal, target. Empty fields are preserved.
# fm-backend.sh owns last-value reads and target selection, exactly as for
# fm-crew-state.sh. This command never probes or changes a runtime endpoint.
# Exits nonzero if any discovered metadata cannot be read; partial output
# must be discarded by the caller.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: fm-endpoint-records.sh <state-dir>' >&2; exit 2; }
for meta in "$1"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  [ -f "$meta" ] && [ -r "$meta" ] || { printf 'unreadable endpoint metadata: %s\n' "$meta" >&2; exit 1; }
  task=${meta##*/}
  task=${task%.meta}
  target=$(fm_backend_target_of_meta "$meta") || target=
  printf '%s\0' "$task" "$meta" "$(fm_meta_get "$meta" project)" \
    "$(fm_meta_get "$meta" kind)" "$(fm_backend_of_meta "$meta")" \
    "$(fm_meta_get "$meta" window)" "$(fm_meta_get "$meta" terminal)" "$target"
done
