#!/usr/bin/env bash
# Live driver: builds disposable FM_HOMEs with real bare origins + clones and runs
# the real bin/fm-fleet-sync.sh (target worktree, and base commit for comparison).
set -u
WT=/home/johannesr/.no-mistakes/worktrees/e0341a3b611a/01M4T1HTZ08BH84STPB5WW9XYR
BASE_SHA=bf552e25f949ceb4a13842af40768cb6861cc008
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$T/base"; git -C "$WT" archive "$BASE_SHA" bin | tar -x -C "$T/base"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

run() { # run <which> <home> [args]
  local which=$1 home=$2; shift 2
  local root=$WT; [ "$which" = base ] && root=$T/base
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}
cm() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$3"; }
# mkproj <home> <name>: bare origin with main, clone in projects/<name>, work repo
mkproj() {
  local h=$1 n=$2
  mkdir -p "$h/projects" "$h/remotes" "$h/data"
  git init -q "$h/work-$n"; git -C "$h/work-$n" symbolic-ref HEAD refs/heads/main
  cm "$h/work-$n" file.txt C0
  git clone -q --bare "$h/work-$n" "$h/remotes/$n.git"
  git -C "$h/work-$n" remote add origin "file://$h/remotes/$n.git"
  git -C "$h/work-$n" push -q -u origin main
  git clone -q "file://$h/remotes/$n.git" "$h/projects/$n"
}
adv() { cm "$1/work-$2" file.txt "$3"; git -C "$1/work-$2" push -q origin main; }
# Reproduce Mosaiq.UIUX.Internal: remote has stale master and HEAD -> master; main advances
mosaiq_shape() {
  local h=$1 n=$2 c=$1/projects/$2
  git -C "$h/work-$n" push -q origin main:refs/heads/master
  git -C "$h/remotes/$n.git" symbolic-ref HEAD refs/heads/master
  git -C "$c" fetch -q origin
  git -C "$c" remote set-head origin -a >/dev/null
  adv "$h" "$n" C1; adv "$h" "$n" C2
}
state() { local c=$1; echo "  HEAD=$(git -C "$c" symbolic-ref --short -q HEAD || echo DETACHED) $(git -C "$c" rev-parse --short HEAD) origin/HEAD=$(git -C "$c" symbolic-ref --short -q refs/remotes/origin/HEAD || echo none) origin/main=$(git -C "$c" rev-parse --short origin/main) status='$(git -C "$c" status --porcelain | tr '\n' ' ')'"; }
hdr() { echo; echo "=== $* ==="; }
fresh() { local h="$T/$1"; rm -rf "$h"; mkdir -p "$h"; echo "$h"; }

N=Mosaiq.UIUX.Internal
for which in base target; do
  hdr "S1 [$which] reported case: $N on main tracking origin/main, origin/HEAD=master, registry branch main (single-project by name)"
  h=$(fresh s1-$which); mkproj "$h" "$N"
  printf -- '- %s [no-mistakes branch=fm/] - UIUX internal (React, branch main) (added 2026-01-01)\n' "$N" > "$h/data/projects.md"
  mosaiq_shape "$h" "$N"; c=$h/projects/$N
  echo "before:"; state "$c"; git -C "$c" rev-parse --abbrev-ref main@{upstream} | sed 's/^/  main upstream=/'
  echo "\$ FM_HOME=\$LAB bin/fm-fleet-sync.sh $N"; run $which "$h" "$N"
  echo "after:"; state "$c"
  echo "  local main == origin/main? $([ "$(git -C "$c" rev-parse main)" = "$(git -C "$c" rev-parse origin/main)" ] && echo yes || echo no)"
  echo "  master untouched local ref present? $(git -C "$c" show-ref -q refs/heads/master && echo yes || echo 'no (never created)')"
done

hdr "S1b [target] same reported shape, whole-fleet form"
h=$(fresh s1b); mkproj "$h" "$N"; printf -- '- %s - UIUX internal (added 2026-01-01)\n' "$N" > "$h/data/projects.md"
mosaiq_shape "$h" "$N"; c=$h/projects/$N; state "$c"
echo "\$ FM_HOME=\$LAB bin/fm-fleet-sync.sh"; run target "$h"; state "$c"

hdr "S2 [target] guard: dirty main in reported shape stays STUCK, edit preserved"
h=$(fresh s2); mkproj "$h" "$N"; mosaiq_shape "$h" "$N"; c=$h/projects/$N
echo edit >> "$c/file.txt"; b=$(git -C "$c" rev-parse --short HEAD)
run target "$h" "$N"; state "$c"; echo "  HEAD unchanged? $([ "$(git -C "$c" rev-parse --short HEAD)" = "$b" ] && echo yes || echo NO)"; echo "  edit kept? $(grep -q edit "$c/file.txt" && echo yes || echo NO)"

hdr "S3 [target] guard: diverged main in reported shape stays STUCK"
h=$(fresh s3); mkproj "$h" "$N"; mosaiq_shape "$h" "$N"; c=$h/projects/$N
cm "$c" local.txt localwork; b=$(git -C "$c" rev-parse --short HEAD)
run target "$h" "$N"; state "$c"; echo "  HEAD unchanged? $([ "$(git -C "$c" rev-parse --short HEAD)" = "$b" ] && echo yes || echo NO)"

hdr "S4 [target] adversarial: main tracks a non-origin remote (upstream) -> must NOT override origin/HEAD"
h=$(fresh s4); mkproj "$h" "$N"; mosaiq_shape "$h" "$N"; c=$h/projects/$N
git -C "$c" remote add upstream "file://$h/remotes/$N.git"; git -C "$c" fetch -q upstream
git -C "$c" branch -q --set-upstream-to=upstream/main main; b=$(git -C "$c" rev-parse --short HEAD)
run target "$h" "$N"; state "$c"; echo "  HEAD unchanged? $([ "$(git -C "$c" rev-parse --short HEAD)" = "$b" ] && echo yes || echo NO)"

hdr "S5 [target] adversarial: feature branch tracking origin/main does NOT get the override"
h=$(fresh s5); mkproj "$h" "$N"; mosaiq_shape "$h" "$N"; c=$h/projects/$N
git -C "$c" checkout -q -b feature --track origin/main 2>/dev/null; git -C "$c" reset -q --hard main
b=$(git -C "$c" rev-parse --short HEAD)
run target "$h" "$N"; state "$c"; echo "  HEAD unchanged? $([ "$(git -C "$c" rev-parse --short HEAD)" = "$b" ] && echo yes || echo NO)"

hdr "S6 [target] decided scope: develop tracking origin/develop with origin/HEAD=main -> compares to origin/HEAD (documented)"
h=$(fresh s6); mkproj "$h" proj; c=$h/projects/proj
git -C "$h/work-proj" push -q origin main:refs/heads/develop; git -C "$c" fetch -q origin
git -C "$c" checkout -q -b develop --track origin/develop
run target "$h" proj; state "$c"

for which in base target; do
  hdr "S7 [$which] restored fallback (F1): no origin/HEAD, on feature, local main exists -> loud STUCK, not benign skip"
  h=$(fresh s7-$which); mkproj "$h" proj; c=$h/projects/proj; adv "$h" proj C1
  git -C "$c" config remote.origin.followRemoteHEAD never; git -C "$c" symbolic-ref --delete refs/remotes/origin/HEAD
  git -C "$c" branch -q --unset-upstream main; git -C "$c" checkout -q -b feature
  run $which "$h" proj; state "$c"

  hdr "S8 [$which] restored fallback (F1): no origin/HEAD, clean detached ancestor -> recovered"
  h=$(fresh s8-$which); mkproj "$h" proj; c=$h/projects/proj; adv "$h" proj C1
  git -C "$c" config remote.origin.followRemoteHEAD never; git -C "$c" symbolic-ref --delete refs/remotes/origin/HEAD
  git -C "$c" branch -q --unset-upstream main; git -C "$c" checkout -q --detach
  run $which "$h" proj; state "$c"
done

hdr "S9 [target] regression: ordinary clone (origin/HEAD=main, on main) behind by 1 -> synced; rerun -> already current"
h=$(fresh s9); mkproj "$h" proj; c=$h/projects/proj; adv "$h" proj C1
run target "$h" proj; run target "$h" proj; state "$c"

hdr "S10 [target] regression: master-default repo (origin/HEAD=master, on master) with stray local main -> master synced, main untouched"
h=$(fresh s10); mkproj "$h" proj; c=$h/projects/proj
git -C "$h/work-proj" push -q origin main:refs/heads/master; git -C "$h/remotes/proj.git" symbolic-ref HEAD refs/heads/master
git -C "$c" fetch -q origin; git -C "$c" remote set-head origin -a >/dev/null; git -C "$c" checkout -q -b master --track origin/master
mb=$(git -C "$c" rev-parse --short main)
cm "$h/work-proj" file.txt M1; git -C "$h/work-proj" push -q origin main:refs/heads/master
run target "$h" proj; state "$c"; echo "  origin/master=$(git -C "$c" rev-parse --short origin/master) main unchanged? $([ "$(git -C "$c" rev-parse --short main)" = "$mb" ] && echo yes || echo NO)"
