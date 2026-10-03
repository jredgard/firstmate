#!/usr/bin/env bash
# lab-run.sh [NAME=VALUE...] <cmd...>: run in the lab's clean env (no inherited FM_* overrides or gateway vars).
. /home/johannesr/.no-mistakes/evidence/01M419TAC0NVR31GRTV07N4E09/lab.env
cd "$LAB"
exec env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=${LANG:-en_US.UTF-8} \
  TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 \
  CLAUDE_CONFIG_DIR="$ROOT/claude-config" FM_HOME="$LAB" "$@"
