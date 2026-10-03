#!/usr/bin/env bash
# fm-claude-gateway-lib.sh - the single resolver for a built-in Claude launch's
# LiteLLM gateway binding. bin/fm-spawn.sh's header owns the binding contract.
#
# Sourced by bin/fm-spawn.sh, which applies the settings to every built-in
# Claude launch, and by bin/fm-control.sh, which resolves the same binding
# before a relaunch stops the running agent, so a binding that cannot resolve
# refuses while nothing has changed yet.

# fm_claude_gateway_settings <harness>: print the CLI --settings JSON fragment
# binding a Claude launch to LITELLM_PROXY_URL. Prints nothing for any other
# harness or when LITELLM_PROXY_URL is unset; refuses (exit 1, message on
# stderr) when the binding cannot resolve uniquely.
fm_claude_gateway_settings() {
  local projects_dir env_file port candidate candidate_port helper
  [ "${1-}" = claude ] && [ "${LITELLM_PROXY_URL+x}" = x ] || return 0
  projects_dir=${LITELLM_PROJECTS_DIR:-$HOME/.config/litellm/projects}
  if ! projects_dir=$(cd "$projects_dir" 2>/dev/null && pwd -P); then
    echo "error: Claude gateway binding requires a readable LiteLLM projects directory; set LITELLM_PROJECTS_DIR or create $HOME/.config/litellm/projects" >&2
    return 1
  fi
  if ! port=$(printf '%s' "$LITELLM_PROXY_URL" | jq -Rer '
    capture("^https?://(?:\\[[^]]+\\]|[^/?#:]+):(?<port>[0-9]+)(?:/[^?#]*)?$").port
  ' 2>/dev/null); then
    echo "error: LITELLM_PROXY_URL must have an explicit gateway port" >&2
    return 1
  fi
  env_file=
  for candidate in "$projects_dir"/*/env; do
    [ -f "$candidate" ] && [ -r "$candidate" ] || continue
    candidate_port=$(awk '
      /^[[:space:]]*(export[[:space:]]+)?LITELLM_PORT[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        sub(/[[:space:]\r]+$/, "")
        if ($0 ~ /^"[0-9]+"$/ || $0 ~ /^\047[0-9]+\047$/) $0 = substr($0, 2, length($0) - 2)
        value = $0
      }
      END { print value }
    ' "$candidate") || return 1
    [ "$candidate_port" = "$port" ] || continue
    if [ -n "$env_file" ]; then
      echo "error: LITELLM_PROXY_URL port $port maps to multiple LiteLLM project env files; configure unique LITELLM_PORT values" >&2
      return 1
    fi
    env_file=$candidate
  done
  if [ -z "$env_file" ]; then
    echo "error: LITELLM_PROXY_URL port $port maps to no readable LiteLLM project env file under $projects_dir; configure LITELLM_PORT" >&2
    return 1
  fi
  # shellcheck disable=SC2016  # The helper script expands at apiKeyHelper runtime, keeping the key out of settings.
  helper="bash -c $(fm_claude_gateway_quote 'set -e; unset LITELLM_MASTER_KEY; . "$1"; test -n "${LITELLM_MASTER_KEY:-}"; printf "%s\n" "$LITELLM_MASTER_KEY"') bash $(fm_claude_gateway_quote "$env_file")"
  jq -cn --arg url "$LITELLM_PROXY_URL" --arg helper "$helper" '
    {env: {ANTHROPIC_BASE_URL: $url, LITELLM_PROXY_URL: $url,
      ANTHROPIC_AUTH_TOKEN: "", ANTHROPIC_API_KEY: ""}, apiKeyHelper: $helper}
  '
}

fm_claude_gateway_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
