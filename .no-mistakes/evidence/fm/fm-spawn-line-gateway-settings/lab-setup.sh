#!/usr/bin/env bash
# Stand up a disposable gateway lab from the run worktree's committed HEAD.
set -euo pipefail
WT=/home/johannesr/.no-mistakes/worktrees/551ff26a6b1c/01M419TAC0NVR31GRTV07N4E09
EV=/home/johannesr/.no-mistakes/evidence/01M419TAC0NVR31GRTV07N4E09
ROOT=$(mktemp -d /tmp/fmgw.XXXXXX); ROOT=$(cd "$ROOT" && pwd -P)
LAB=$ROOT/home

echo "ROOT=$ROOT" > "$EV/lab.env"; echo "NONCE=$NONCE" >> "$EV/lab.env"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$LAB" init -q -b main
git -C "$LAB" fetch -q "$WT" HEAD
git -C "$LAB" checkout -q -f -B main FETCH_HEAD
git -C "$LAB" config user.name lab; git -C "$LAB" config user.email lab@example.invalid
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse"
printf 'tmux\n' > "$LAB/config/backend"
printf 'claude\n' > "$LAB/config/crew-harness"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
echo "tree=$(git -C "$LAB" rev-parse HEAD)"

# Fixture LiteLLM projects dir mirroring the real layout (ports shifted to free loopback ports).
P=$ROOT/litellm-projects
mkdir -p "$P/mosaiq" "$P/clims" "$P/templatecontrol" "$P/_template"
printf 'LITELLM_PORT=14000\nLITELLM_MASTER_KEY=fx-mosaiq-key-%s\n' "$NONCE" > "$P/mosaiq/env"
printf 'LITELLM_PORT=14001\nLITELLM_MASTER_KEY=fx-clims-key-%s\nAZURE_AI_RESOURCE=we-dev-clims-aif\n' "$NONCE" > "$P/clims/env"
printf 'export LITELLM_PORT="14006"\nLITELLM_MASTER_KEY="fx-tc-key-%s"\nAZURE_AI_RESOURCE=we-dev-templatecontrol-aif\n' "$NONCE" > "$P/templatecontrol/env"
printf 'LITELLM_PORT=400X\nLITELLM_MASTER_KEY=changeme\n' > "$P/_template/env"
cat > "$ROOT/keys.json" <<EOF
{"mosaiq-line-key":"fx-mosaiq-key-$NONCE","clims-line-key":"fx-clims-key-$NONCE",
 "clims-rotated-key":"fx-clims-rotated-$NONCE","templatecontrol-line-key":"fx-tc-key-$NONCE",
 "stale-user-settings-token":"stale-user-token-$NONCE","stale-shell-auth-token":"stale-shell-token-$NONCE",
 "stale-shell-api-key":"stale-shell-apikey-$NONCE"}
EOF

# Isolated Claude config whose USER settings pin the stale Mosaiq URL/token (the reported conflict).
C=$ROOT/claude-config; mkdir -p "$C"
cat > "$C/settings.json" <<EOF
{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:14000","ANTHROPIC_AUTH_TOKEN":"stale-user-token-$NONCE"}}
EOF
printf '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.288","numStartups":5}\n' > "$C/.claude.json"

# Lab project with a lab-private origin.
seed=$ROOT/origins/notes-seed; origin=$ROOT/origins/notes.git
mkdir -p "$seed"; git init -q -b main "$seed"; printf '# notes\n' > "$seed/README.md"
git -C "$seed" add -A; git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$origin"; rm -rf "$seed"
git clone -q "$origin" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"

TMUX_DIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
echo "TMUX_DIR=$TMUX_DIR" >> "$EV/lab.env"; echo "LAB=$LAB" >> "$EV/lab.env"
# The pane environment carries STALE shell exports, like an fm shell whose user settings/env still name Mosaiq.
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=${LANG:-en_US.UTF-8} \
  TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 \
  CLAUDE_CONFIG_DIR="$C" ANTHROPIC_BASE_URL=http://127.0.0.1:14000 \
  ANTHROPIC_AUTH_TOKEN="stale-shell-token-$NONCE" ANTHROPIC_API_KEY="stale-shell-apikey-$NONCE" \
  tmux -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT"
nohup python3 "$EV/fake-gateway.py" 14000,14001,14006 "$ROOT/gateway.jsonl" "$ROOT/keys.json" >"$ROOT/gateway.err" 2>&1 &
echo "GW_PID=$!" >> "$EV/lab.env"
cat "$EV/lab.env"
