#!/usr/bin/env bash
# Live repro: Mosaiq.UIUX.Internal-shaped clone in a disposable lab home.
set -u
WT=$1; OUT=$2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX")
trap 'rm -rf "$LAB" "$BASE"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$WT" archive 3db82013099a937d89b49f3d51e24a37f7d85a85 | tar -x -C "$BASE"
say() { printf '%s\n' "$*"; }
cm() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$3"; }

# mk <name>: remote whose HEAD is master (stale), main is the real line; clone on main tracking origin/main.
mk() {
  local n=$1 w="$LAB/work/$1" r="$LAB/remotes/$1.git" c="$LAB/projects/$1"
  mkdir -p "$LAB/work" "$LAB/remotes"
  git init -q "$w"; git -C "$w" symbolic-ref HEAD refs/heads/master
  cm "$w" f.txt M0; git -C "$w" branch main
  git clone -q --bare "$w" "$r"; git -C "$r" symbolic-ref HEAD refs/heads/master
  git -C "$w" remote add origin "file://$r"
  git clone -q "file://$r" "$c"
  git -C "$c" checkout -q -b main --track origin/main
  git -C "$c" branch -q -D master
  git -C "$w" checkout -q main; cm "$w" f.txt "main-C1"; cm "$w" f.txt "main-C2"; git -C "$w" push -q origin main
  git -C "$w" checkout -q master; cm "$w" g.txt "master-only"; git -C "$w" push -q origin master
}
run() { # run <root> <args...>
  local root=$1; shift
  FM_HOME="$LAB" "$root/bin/fm-fleet-sync.sh" "$@" 2>&1
}
state() { local c="$LAB/projects/$1"
  say "  HEAD branch: $(git -C "$c" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)  local main=$(git -C "$c" rev-parse --short main)  origin/main=$(git -C "$c" rev-parse --short origin/main)  origin/HEAD=$(git -C "$c" symbolic-ref --short refs/remotes/origin/HEAD)  upstream=$(git -C "$c" rev-parse --abbrev-ref main@{upstream})"; }

N=Mosaiq.UIUX.Internal
printf -- '- %s [no-mistakes] - UI/UX internal (React, branch main) (added 2026-01-01)\n' "$N" > "$LAB/data/projects.md"

say "=== S1 regression repro: BASE commit 3db8201, $N on main tracking origin/main, origin/HEAD=master ==="
mk $N; state $N
say "\$ FM_HOME=\$LAB fm-fleet-sync.sh $N   (base)"; run "$BASE" $N; state $N
say
say "=== S1 fixed: TARGET commit, same clone state ==="
say "\$ FM_HOME=\$LAB fm-fleet-sync.sh $N   (target)"; run "$WT" $N; state $N
say "\$ second run (target)"; run "$WT" $N
say
say "=== S2 whole-fleet form (no args), fresh clone ==="
rm -rf "$LAB/projects/$N" "$LAB/work/$N" "$LAB/remotes/$N.git"; mk $N; state $N
say "\$ FM_HOME=\$LAB fm-fleet-sync.sh"; run "$WT"; state $N
say
say "=== S3 guard: dirty main tracking origin/main stays untouched (STUCK) ==="
rm -rf "$LAB/projects/$N" "$LAB/work/$N" "$LAB/remotes/$N.git"; mk $N
echo wip >> "$LAB/projects/$N/f.txt"; b=$(git -C "$LAB/projects/$N" rev-parse main)
run "$WT" $N; [ "$(git -C "$LAB/projects/$N" rev-parse main)" = "$b" ] && say "  main unchanged; wip preserved: $(git -C "$LAB/projects/$N" status --porcelain)"
say
say "=== S4 guard: local main diverged from origin/main -> STUCK diverged, untouched ==="
rm -rf "$LAB/projects/$N" "$LAB/work/$N" "$LAB/remotes/$N.git"; mk $N
cm "$LAB/projects/$N" h.txt local-unique; b=$(git -C "$LAB/projects/$N" rev-parse main)
run "$WT" $N; [ "$(git -C "$LAB/projects/$N" rev-parse main)" = "$b" ] && say "  main unchanged at $(git -C "$LAB/projects/$N" rev-parse --short main)"
say
say "=== S5 guard: feature branch tracking origin/feature, origin/HEAD=master -> still STUCK off-default (not synced to its own upstream) ==="
rm -rf "$LAB/projects/$N" "$LAB/work/$N" "$LAB/remotes/$N.git"; mk $N
w="$LAB/work/$N"; git -C "$w" checkout -q -b feat main; cm "$w" f.txt feat1; git -C "$w" push -q origin feat
c="$LAB/projects/$N"; git -C "$c" fetch -q origin; git -C "$c" checkout -q -b feat --track origin/feat~1 2>/dev/null || { git -C "$c" checkout -q -b feat origin/feat~1; git -C "$c" branch -q --set-upstream-to=origin/feat; }
b=$(git -C "$c" rev-parse feat); run "$WT" $N; [ "$(git -C "$c" rev-parse feat)" = "$b" ] && say "  feat unchanged"
say
say "=== S6 regression guard: clone on master tracking origin/master with origin/HEAD=master still syncs ==="
n2=classic; printf -- '- %s [no-mistakes] - classic\n- %s [no-mistakes] - x\n' "$n2" "$N" > "$LAB/data/projects.md"
w="$LAB/work/$n2"; r="$LAB/remotes/$n2.git"; c="$LAB/projects/$n2"
git init -q "$w"; git -C "$w" symbolic-ref HEAD refs/heads/master; cm "$w" f.txt c0
git clone -q --bare "$w" "$r"; git -C "$w" remote add origin "file://$r"; git clone -q "file://$r" "$c"
cm "$w" f.txt c1; git -C "$w" push -q origin master
run "$WT" $n2; say "  master=$(git -C "$c" rev-parse --short master) origin/master=$(git -C "$c" rev-parse --short origin/master)"
say
say "=== S7 fallback: main with no upstream + origin/HEAD=master -> uses origin/HEAD (pre-existing behavior) ==="
rm -rf "$LAB/projects/$N" "$LAB/work/$N" "$LAB/remotes/$N.git"; mk $N
git -C "$LAB/projects/$N" branch -q --unset-upstream main
run "$WT" $N
