setup() {
  printf 'pr=https://dev.azure.com/acme/project/_git/Mosaiq.Codegraph/pullrequest/59397\n' >> "$ST/demo.meta"

}
trigger() {
  FM_STATE_OVERRIDE="$ST" bash -c '. "$1"; fm_wake_append check ado-pr-sweep "$2"' _ "$WT/bin/fm-wake-lib.sh" \
    "check: $ST/ado-pr-sweep.check.sh: ado-pr-sweep: PR 59390 has MERGE CONFLICTS (Mosaiq.X) - Rework X
ado-pr-sweep: PR 59396 MERGED (Mosaiq.Codegraph) - Earlier lane already torn down
ado-pr-sweep: PR 59397 MERGED (Mosaiq.Codegraph) - demo lane PR"
}
