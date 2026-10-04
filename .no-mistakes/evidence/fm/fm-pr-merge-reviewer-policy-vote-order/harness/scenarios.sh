#!/usr/bin/env bash
# Drives every live scenario against the disposable forge emulator.
LAB=/tmp/fm-lab.V0GmFX
WT=/home/johannesr/.no-mistakes/worktrees/551ff26a6b1c/01M443Y636779T2GZQNWYHNYJJ
EV=/home/johannesr/.no-mistakes/evidence/01M443Y636779T2GZQNWYHNYJJ
ADO_URL=https://dev.azure.com/acme/DS_mosaiq-poc/_git/Mosaiq/pullrequest/57712
GH_URL=https://github.com/acme/widgets/pull/9
REV=22222222-3333-4444-5555-666666666666
cd "$LAB"
mutate() { jq "$1" "$LAB/state.json" > "$LAB/state.tmp" && mv "$LAB/state.tmp" "$LAB/state.json"; }
away() { env -u NO_MISTAKES_GATE FM_HOME="$LAB/home" "$WT/bin/fm-afk-contract.sh" enter --words 'merge the green PRs while I am away' >/dev/null || echo "away enter failed"; }
unaway() { env -u NO_MISTAKES_GATE FM_HOME="$LAB/home" "$WT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || true; }
# case <name> <task> <base-json> <jq-mutation> <env-assignments> -- <merge args...>
run_case() {
  local name=$1 task=$2 base=$3 mut=$4 envs=$5; shift 6
  local out="$EV/$name.txt" rc
  "$LAB/new-case.sh" "$task" "$LAB/$base"
  [ "$mut" = . ] || mutate "$mut"
  rm -rf "$LAB/user-home/.cache/gh"
  : > "$LAB/requests.log"
  local before; before=$(jq -c . "$LAB/state.json")
  local runner="$LAB/run-merge.sh"
  [ -z "${USE_BASE:-}" ] || runner="$LAB/run-merge-base.sh"
  local start=$SECONDS
  env $envs "$runner" "$task" "$@" > "$LAB/out" 2> "$LAB/err"; rc=$?
  {
    echo "### scenario: $name"
    echo "### script: $( [ -n "${USE_BASE:-}" ] && echo "base commit e7cf1551 bin/fm-pr-merge.sh" || echo "change under test 95ccaa89 bin/fm-pr-merge.sh")"
    echo "### command: ${envs:+$envs }fm-pr-merge.sh $task $*"
    echo "### away record present: $( [ -f "$LAB/home/state/.afk-contract" ] && echo yes || echo no)"
    echo "### emulator state before: $before"
    echo "### exit code: $rc   (elapsed $((SECONDS-start))s)"
    echo "### stdout:"; cat "$LAB/out"
    echo "### stderr (watcher-supervision banners from the lab home filtered):"; grep -v '^●\|^WARNING: watcher\|^WARNING: queued wakes' "$LAB/err"
    echo "### forge requests seen by the emulator:"; cut -c1-330 "$LAB/requests.log"
    echo "### emulator state after: $(jq -c . "$LAB/state.json")"
    echo "### task meta after:"; cat "$LAB/home/state/$task.meta"
  } > "$out"
  echo "$name rc=$rc elapsed=$((SECONDS-start))s"
}
"$@"
