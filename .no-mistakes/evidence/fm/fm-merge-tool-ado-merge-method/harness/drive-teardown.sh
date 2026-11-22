#!/usr/bin/env bash
# drive-teardown.sh <label> <firstmate-root> <strategy-policies-json-array>
# Merge through the real fm-pr-merge.sh against the local HTTPS ADO emulator,
# then run the real fm-teardown.sh --merged-pr against the same emulator, in a
# marked disposable lab home whose project is a real clone with a git worktree.
set -u
LABEL=$1 FMROOT=$2 POLICIES=$3
H=$(cd "$(dirname "$0")" && pwd); EV=$(dirname "$H"); OUT="$EV/scenarios/$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-ado-emu.XXXXXX")
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
umask 022
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=fm-lab-ca" -keyout "$RUN/ca.key" -out "$RUN/ca.pem" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=dev.azure.com" -keyout "$RUN/leaf.key" -out "$RUN/leaf.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:dev.azure.com\n' > "$RUN/ext"
openssl x509 -req -in "$RUN/leaf.csr" -CA "$RUN/ca.pem" -CAkey "$RUN/ca.key" -CAcreateserial -days 2 -extfile "$RUN/ext" -out "$RUN/leaf.pem" >/dev/null 2>&1

git init -q -b main "$RUN/seed"; printf '# Backend\n' > "$RUN/seed/README.md"; git -C "$RUN/seed" add .; git -C "$RUN/seed" commit -qm initial
git clone -q --bare "$RUN/seed" "$RUN/Backend.git"
git -C "$RUN/Backend.git" symbolic-ref HEAD refs/heads/main
git clone -q "$RUN/Backend.git" "$RUN/project"
git -C "$RUN/project" remote set-head origin main
git -C "$RUN/project" worktree add -q -b fm/example "$RUN/wt" main
printf 'feature\n' > "$RUN/wt/feature.txt"; git -C "$RUN/wt" add .; git -C "$RUN/wt" commit -qm 'Add feature'
git -C "$RUN/wt" push -q -u origin fm/example
git clone -q "$RUN/Backend.git" "$RUN/other"; printf 'other\n' > "$RUN/other/other.txt"
git -C "$RUN/other" add .; git -C "$RUN/other" commit -qm 'Unrelated main change'; git -C "$RUN/other" push -q origin main
git -C "$RUN/project" fetch -q origin

LAB="$RUN/lab"
"$FMROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi add task-x1 "ADO merge-commit fixture task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$RUN/wt" "project=$RUN/project" \
  "kind=ship" "branch=fm/example" "mode=direct-PR" "spawn_gen=lab-task-x1" > "$LAB/state/task-x1.meta"
touch "$LAB/state/.last-watcher-beat"

# Boundary stand-ins for operator tools (token minting, pool/pipeline/GitHub/tmux) so nothing reaches real state.
mkdir -p "$RUN/bin" "$RUN/curlhome" "$RUN/user-home" "$RUN/emu"
cat > "$RUN/bin/az" <<'AZ'
#!/usr/bin/env bash
[ "$*" = 'account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv' ] || exit 3
printf '%s\n' emulator-token
AZ
for t in treehouse tmux gh no-mistakes; do printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "$FM_EMU_TOOL_LOG"\nexit 0\n' "$t" > "$RUN/bin/$t"; done
cat > "$RUN/bin/gh-axi" <<'GA'
#!/usr/bin/env bash
printf '%s\n' "gh-axi $*" >> "$FM_EMU_TOOL_LOG"
case "${1:-} ${2:-}" in "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac
exit 0
GA
chmod +x "$RUN/bin/"*
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
printf 'connect-to = "dev.azure.com:443:127.0.0.1:%s"\ncacert = "%s"\n' "$PORT" "$RUN/ca.pem" > "$RUN/curlhome/.curlrc"
jq -n --arg repo "$RUN/Backend.git" --argjson pol "$POLICIES" \
  '{repo:$repo,target:"main",source:"fm/example",token:"emulator-token",strategy_policies:$pol}' > "$RUN/emu/config.json"
python3 -I "$H/ado_emulator.py" "$PORT" "$RUN/leaf.pem" "$RUN/leaf.key" "$RUN/emu" 2> "$RUN/emu/server.err" &
EMU=$!
for _ in $(seq 50); do [ -e "$RUN/emu/ready" ] && break; sleep 0.1; done
URL='https://dev.azure.com/acme/Project%20One/_git/Backend/pullrequest/42'
runfm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u TMUX \
    FM_HOME="$LAB" HOME="$RUN/user-home" CURL_HOME="$RUN/curlhome" TMUX_TMPDIR="$LAB/tmux" FM_EMU_TOOL_LOG="$RUN/tools.log" \
    PATH="$RUN/bin:$PATH" FM_ADO_REVIEWER_ID=22222222-2222-2222-2222-222222222222 "$@"
}
{
  echo "# blocking merge-strategy policy settings on main: $POLICIES"
  echo "\$ fm-pr-merge.sh task-x1 $URL"
  runfm "$FMROOT/bin/fm-pr-merge.sh" task-x1 "$URL" </dev/null 2>&1 | grep -v '●'; echo "exit=${PIPESTATUS[0]}"
  echo "--- emulator completion record"; cat "$RUN/emu/completed.json"; echo
  echo "--- target branch main (git log --graph)"; git -C "$RUN/Backend.git" log --graph --format='%h parents=[%p] %s' main
  echo "--- PR source branch deleted on the forge after completion (as with deleteSourceBranch), worktree still present"
  git -C "$RUN/Backend.git" branch -D fm/example >/dev/null 2>&1 || true
  git -C "$RUN/project" fetch -q --prune origin
  echo "\$ fm-teardown.sh task-x1 --merged-pr $URL"
  runfm "$FMROOT/bin/fm-teardown.sh" task-x1 --merged-pr "$URL" </dev/null 2>&1 | grep -v '●'; echo "exit=${PIPESTATUS[0]}"
  echo "--- task meta present after teardown?"; [ -f "$LAB/state/task-x1.meta" ] && echo yes || echo "no (retired)"
  echo "--- backlog row"; tasks-axi show task-x1 --file "$LAB/data/backlog.md" --full 2>&1 | head -20
  echo "--- operator-tool stand-in calls"; cat "$RUN/tools.log" 2>/dev/null
} > "$OUT/transcript.txt" 2>&1
kill "$EMU" 2>/dev/null; wait "$EMU" 2>/dev/null
cp "$RUN/emu/requests.log" "$OUT/emulator-requests.log" 2>/dev/null
rm -rf "$RUN"
cat "$OUT/transcript.txt"
