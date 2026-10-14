setup() { rm -f "$ST/demo.meta"; }
trigger() {
  FM_STATE_OVERRIDE="$ST" bash -c '. "$1"; fm_wake_append check ado-pr-sweep "$2"' _ "$WT/bin/fm-wake-lib.sh" \
    "check: $ST/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59397 MERGED (Mosaiq.Codegraph) - Add codegraph indexer"
}
