#!/usr/bin/env bash
# drive.sh <label> <firstmate-root> <strategy-policies-json-array> [keep]
# Runs the real <firstmate-root>/bin/fm-pr-merge.sh against a disposable local
# HTTPS Azure DevOps emulator backed by a real git repo, in a disposable lab home.
set -u
LABEL=$1 FMROOT=$2 POLICIES=$3 KEEP=${4:-}
H=$(cd "$(dirname "$0")" && pwd)
EV=$(dirname "$H")
OUT="$EV/scenarios/$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-ado-emu.XXXXXX")
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
umask 022

# TLS: a throwaway CA and a dev.azure.com leaf cert.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=fm-lab-ca" -keyout "$RUN/ca.key" -out "$RUN/ca.pem" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=dev.azure.com" -keyout "$RUN/leaf.key" -out "$RUN/leaf.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:dev.azure.com\n' > "$RUN/ext"
openssl x509 -req -in "$RUN/leaf.csr" -CA "$RUN/ca.pem" -CAkey "$RUN/ca.key" -CAcreateserial -days 2 -extfile "$RUN/ext" -out "$RUN/leaf.pem" >/dev/null 2>&1

# Forge repository: main + fm/example with one change.
git init -q -b main "$RUN/seed"
printf '# Backend\n' > "$RUN/seed/README.md"; git -C "$RUN/seed" add .; git -C "$RUN/seed" commit -qm initial
git clone -q --bare "$RUN/seed" "$RUN/Backend.git"
git clone -q "$RUN/Backend.git" "$RUN/wt"
git -C "$RUN/wt" checkout -q -b fm/example
printf 'feature\n' > "$RUN/wt/feature.txt"; git -C "$RUN/wt" add .; git -C "$RUN/wt" commit -qm 'Add feature'
git -C "$RUN/wt" push -q origin fm/example
# main moves on, so a merge is a real merge (not a fast-forward)
git clone -q "$RUN/Backend.git" "$RUN/other"; printf 'other\n' > "$RUN/other/other.txt"
git -C "$RUN/other" add .; git -C "$RUN/other" commit -qm 'Unrelated main change'; git -C "$RUN/other" push -q origin main
git -C "$RUN/wt" fetch -q origin
HEAD_SHA=$(git -C "$RUN/wt" rev-parse HEAD)

# Disposable lab home.
LAB="$RUN/lab"
"$FMROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || { [ -x "$FMROOT/bin/fm-lab-home.sh" ] || mkdir -p "$LAB/state" "$LAB/data" "$LAB/config"; }
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf '%s\n' "window=fm-task-x1" "worktree=$RUN/wt" "project=$RUN/seed" "kind=ship" "branch=fm/example" "mode=direct-PR" > "$LAB/state/task-x1.meta"

# The Azure CLI token boundary: a stand-in that only mints the emulator's token.
mkdir -p "$RUN/bin" "$RUN/curlhome" "$RUN/user-home" "$RUN/emu"
cat > "$RUN/bin/az" <<'AZ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_EMU_AZ_LOG"
[ "$*" = 'account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv' ] || exit 3
printf '%s\n' emulator-token
AZ
chmod +x "$RUN/bin/az"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
printf 'connect-to = "dev.azure.com:443:127.0.0.1:%s"\ncacert = "%s"\n' "$PORT" "$RUN/ca.pem" > "$RUN/curlhome/.curlrc"
jq -n --arg repo "$RUN/Backend.git" --argjson pol "$POLICIES" \
  '{repo:$repo,target:"main",source:"fm/example",token:"emulator-token",strategy_policies:$pol}' > "$RUN/emu/config.json"
python3 -I "$H/ado_emulator.py" "$PORT" "$RUN/leaf.pem" "$RUN/leaf.key" "$RUN/emu" 2> "$RUN/emu/server.err" &
EMU=$!
for _ in $(seq 50); do [ -e "$RUN/emu/ready" ] && break; sleep 0.1; done

URL='https://dev.azure.com/acme/Project%20One/_git/Backend/pullrequest/42'
{
  echo "\$ fm-pr-merge.sh task-x1 $URL   # firstmate root: $FMROOT"
  echo "# blocking merge-strategy policy settings on main: $POLICIES"
  echo "# PR source head: $HEAD_SHA"
} > "$OUT/transcript.txt"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u TMUX \
  FM_HOME="$LAB" HOME="$RUN/user-home" CURL_HOME="$RUN/curlhome" FM_EMU_AZ_LOG="$RUN/az.log" \
  PATH="$RUN/bin:$PATH" FM_ADO_REVIEWER_ID=22222222-2222-2222-2222-222222222222 FM_PR_REVIEW_COMMENT_WAIT=1 \
  "$FMROOT/bin/fm-pr-merge.sh" task-x1 "$URL" </dev/null > "$OUT/stdout" 2> "$OUT/stderr"
RC=$?
{
  echo "--- stdout"; cat "$OUT/stdout"; echo "--- stderr"; cat "$OUT/stderr"; echo "--- exit=$RC"
  echo "--- requests seen by the Azure DevOps emulator (method path body)"
  sed -E 's/(policy\/evaluations\?)[^ ]*/\1.../' "$RUN/emu/requests.log"
  echo "--- emulator completion record"; cat "$RUN/emu/completed.json" 2>/dev/null || echo "(not completed)"
  echo "--- target branch main after the run (git log --graph --format='%h %p %s')"
  git -C "$RUN/Backend.git" log --graph --format='%h parents=[%p] %s' main
  echo "--- task meta"; cat "$LAB/state/task-x1.meta"
} >> "$OUT/transcript.txt"
echo "$RC" > "$OUT/exit"
kill "$EMU" 2>/dev/null; wait "$EMU" 2>/dev/null
cp "$RUN/emu/requests.log" "$OUT/emulator-requests.log" 2>/dev/null
cp "$RUN/emu/server.err" "$OUT/emulator-server.err" 2>/dev/null
if [ -n "$KEEP" ]; then echo "$RUN" > "$OUT/rundir"; else rm -rf "$RUN"; fi
cat "$OUT/transcript.txt"
