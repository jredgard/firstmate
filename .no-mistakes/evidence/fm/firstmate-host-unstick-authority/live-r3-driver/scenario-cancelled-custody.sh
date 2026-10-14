. /tmp/fm-live-drv/common.sh
setup() {
  git init -q --bare -b fm/demo "$LAB/projects/demo-origin.git"
  gitrepo
  printf 'feature\n' > "$WTD/feature.txt"; git -C "$WTD" add feature.txt; git -C "$WTD" -c user.name=w -c user.email=w@x commit -q -m "task: feature"
  git -C "$WTD" remote add origin "$LAB/projects/demo-origin.git"
  local old; old=$(git -C "$WTD" rev-parse HEAD)
  printf 'fix\n' >> "$WTD/feature.txt"; git -C "$WTD" -c user.name=nm -c user.email=nm@x commit -q -am "no-mistakes(review): fix round"
  git -C "$WTD" push -q origin fm/demo
  REQ=$(git -C "$WTD" rev-parse HEAD)
  git -C "$WTD" reset -q --hard "$old"
  printf 'daemon: running (healthy)\nrun 01RUNCANCEL branch=fm/demo status=cancelled (terminal) head=%s\nno active or newer run owns fm/demo\n' "$REQ" > "$SCR/nm-default.out"
}
trigger() { status_blocked "no-mistakes run 01RUNCANCEL was cancelled; relaunch refused: 'branch custody: local head $(git -C "$WTD" rev-parse --short HEAD) differs from the pushed head $REQ required by the gate'. Worktree $WTD is clean. Should I reset my branch to the pushed head?"; }
