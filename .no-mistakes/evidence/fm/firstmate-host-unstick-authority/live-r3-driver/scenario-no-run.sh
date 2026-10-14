. /tmp/fm-live-drv/common.sh
setup() {
  gitrepo
  printf 'daemon: running (healthy, pid 4242)\nbranch fm/demo: no run (no active, pending, or recent run owns this branch)\n' > "$SCR/nm-default.out"
}
trigger() { status_blocked "I launched no-mistakes validation for branch fm/demo in the background 4 minutes ago but no run was ever created (axi status shows no run). Worktree $WTD is committed and clean. How should I proceed?"; }
