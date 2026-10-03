#!/usr/bin/env bash
# Read-only project conflict candidates; writes only private radar memory.
# Usage: fm-conflict-radar.sh [--json] [project-name]
# No project selects projects with multiple tracked ship metas, including ships
# awaiting validation or landing. Metadata is retained until task teardown;
# status tails are not consulted as a liveness or completion authority.
# Project names match a recorded project's basename (or a literal name).
# FM_HOME, FM_STATE_OVERRIDE and FM_DATA_OVERRIDE select the operational home.
# Git/GitHub commands use fm-timeout-lib.sh; Azure requests use fm-pr-lib.sh's
# bounded token acquisition and curl timeout. FM_CONFLICT_RADAR_TIMEOUT sets
# their positive whole-second bound (default 20). No fetch, checkout, index
# refresh, steering, merge, or project write is performed. Requires Git and jq;
# optional forge reads use gh-axi API or fm-pr-lib.sh Azure bearer requests.
# Task bases always use local origin/HEAD;
# missing refs are unmeasured, never repaired by fetching. Deltas include
# committed, staged, unstaged, untracked and both sides of renamed paths.
# Registry ledgers are queried only through fm-project-mode.sh --ledgers.
# Built-in ledgers: .md/.markdown/.rst/.adoc and documentation basenames
# README, INDEX, CHANGELOG, NOTES, VERIFY and BUILD-STATUS, optionally .txt.
# Other .txt files are code except requirements*.txt/constraints*.txt, which
# are mechanical. Registry ledgers override these built-in classes.
# Mechanical: .csproj/.fsproj/.vbproj, Directory.{Packages,Build}.props,
# packages.lock.json, package-lock.json, npm-shrinkwrap.json, *.lock,
# global.json, package.json, pnpm-lock.yaml,
# .properties/.ini/.env and .editorconfig/.npmrc/.yarnrc key-value settings;
# structured .config and unspecified JSON/YAML remain code candidates.
# state/conflict-radar/<project>.json holds schema_version, project,
# project_path, timestamp, ledgers, sources, matrix and unmeasured. Sources
# carry task/PR ids, task associations, paths, measurement, status and last
# observed time. Measured Azure PR sources also carry iteration_id; paths are
# reused only for the same PR and iteration after one latest-iteration read.
# One process-local Azure token is reused across all requests in a radar run.
# Matrix sources name evidence; participants collapse a task
# and its own PR so they alone never constitute an overlap.
# Fresh measured paths replace prior paths; failed reads retain prior paths.
# Closed PR evidence remains while an associated task meta exists. When both
# task meta and PR are gone, the source is pruned; failed PR reads retain it.
# JSON stdout is {projects:[<memory>...]}. Human output names every shared
# path and unmeasured source; "no overlap" is
# printed only when every relevant source and the forge were measured.
# Exit 0 includes partial observations, explicitly marked unmeasured; exit 1
# is a local dependency, argument, malformed memory or persistence failure.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
export FM_HOME FM_DATA_OVERRIDE="$DATA"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
export GIT_OPTIONAL_LOCKS=0

FORMAT=human
PROJECT=
for argument in "$@"; do
  case "$argument" in
    --json) FORMAT=json ;;
    --help|-h) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'error: unknown option %s\n' "$argument" >&2; exit 1 ;;
    *) [ -z "$PROJECT" ] || { echo 'error: expected one project' >&2; exit 1; }; PROJECT=$argument ;;
  esac
done
TIMEOUT=${FM_CONFLICT_RADAR_TIMEOUT:-20}
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo 'error: invalid radar timeout' >&2; exit 1; }
if ! command -v jq >/dev/null || ! command -v git >/dev/null; then
  echo 'error: Git and jq required' >&2
  exit 1
fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-conflict-radar.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
printf '[]\n' > "$SCRATCH/tasks.json"
printf '[]\n' > "$SCRATCH/projects.json"

radar_git() {
  local worktree=$1
  shift
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  fm_run_timed "$TIMEOUT" git -c core.fsmonitor=false -c core.untrackedCache=false -C "$worktree" "$@"
}

gh_json() {
  local response encoded
  response=$(fm_run_timed "$TIMEOUT" gh-axi api GET "$1" --jq '@base64' --full 2>/dev/null) || return 1
  printf '%s\n' "$response" | awk '/^  truncated: / {if ($2=="false") found=1} END {exit !found}' || return 1
  encoded=$(printf '%s\n' "$response" | awk '/^  body: / {sub(/^  body: /, ""); print; exit}')
  [ -n "$encoded" ] || return 1
  printf '%s\n' "$encoded" | jq -R 'fromjson? // .' | jq -e '@base64d | fromjson'
}

ado_json() {
  FM_PR_ADO_TIMEOUT="$TIMEOUT" fm_pr_ado_request GET "$1" 2>/dev/null
}

append_source() {
  printf '%s\n' "$1" >> "$SCRATCH/sources.jsonl"
}

unmeasured() {
  printf '%s\n' "$1" | jq -R '.' >> "$SCRATCH/unmeasured.jsonl"
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  [ "${kind:-ship}" = ship ] || continue
  recorded=$(fm_meta_get "$meta" project)
  [ -n "$recorded" ] || continue
  name=${recorded%/}; name=${name##*/}
  task_id=${meta##*/}; task_id=${task_id%.meta}
  jq --arg project "$name" --arg project_path "$recorded" --arg id "task:$task_id" \
    --arg task_id "$task_id" --arg worktree "$(fm_meta_get "$meta" worktree)" \
    --arg branch "$(fm_meta_get "$meta" branch)" --arg pr_url "$(fm_meta_get "$meta" pr)" \
    '. + [{project:$project,project_path:$project_path,id:$id,kind:"task",task_id:$task_id,
      worktree:$worktree,branch:$branch,pr_url:$pr_url}]' \
    "$SCRATCH/tasks.json" > "$SCRATCH/next.json"
  mv "$SCRATCH/next.json" "$SCRATCH/tasks.json"
done
if [ -n "$PROJECT" ]; then
  printf '%s\n' "$PROJECT" | jq -R '.' > "$SCRATCH/names.jsonl"
else
  jq -c 'group_by(.project)[] | select(length>1) | .[0].project' "$SCRATCH/tasks.json" > "$SCRATCH/names.jsonl"
fi

forge_identity() {
  local origin=$1 candidate
  PROVIDER=none
  REPOSITORY=
  ADO_BASE=
  case "$origin" in
    https://*@dev.azure.com/*) origin="https://dev.azure.com/${origin#*dev.azure.com/}" ;;
    https://*@github.com/*) origin="https://github.com/${origin#*github.com/}" ;;
  esac
  case "$origin" in
    https://github.com/*|git@github.com:*|ssh://git@github.com/*)
      candidate=${origin#https://github.com/}; candidate=${candidate#git@github.com:}
      candidate=${candidate#ssh://git@github.com/}; candidate=${candidate%.git}
      if fm_pr_url_parse "https://github.com/$candidate/pull/1"; then
        PROVIDER=github; REPOSITORY=$FM_PR_PATH
      fi ;;
    https://dev.azure.com/*)
      candidate=${origin%.git}
      if fm_pr_ado_base "$candidate/pullrequest/1"; then
        PROVIDER=ado; ADO_BASE=${FM_PR_ADO_BASE%/pullRequests/1}
      fi ;;
    git@ssh.dev.azure.com:v3/*|ssh://git@ssh.dev.azure.com/v3/*)
      candidate=${origin#git@ssh.dev.azure.com:v3/}; candidate=${candidate#ssh://git@ssh.dev.azure.com/v3/}
      local org project repo extra
      IFS=/ read -r org project repo extra <<< "$candidate"
      if [ -z "$extra" ] && fm_pr_ado_base "https://dev.azure.com/$org/$project/_git/$repo/pullrequest/1"; then
        PROVIDER=ado; ADO_BASE=${FM_PR_ADO_BASE%/pullRequests/1}
      fi ;;
  esac
}

pr_files() {
  local number=$1 url=$2 page=1 response count iteration cached skip=0 next_skip next_top=100
  PR_ITERATION=
  printf '[]\n' > "$SCRATCH/pr-paths.json"
  if [ "$PROVIDER" = github ]; then
    while [ "$page" -le 30 ]; do
      response=$(gh_json "/repos/$REPOSITORY/pulls/$number/files?per_page=100&page=$page") || return 1
      printf '%s' "$response" | jq -e 'type=="array" and all(.[]; (.filename|type)=="string")' >/dev/null || return 1
      count=$(printf '%s' "$response" | jq 'length')
      jq --argjson response "$response" '. + [$response[] | .filename, .previous_filename // empty] | unique' \
        "$SCRATCH/pr-paths.json" > "$SCRATCH/next.json"
      mv "$SCRATCH/next.json" "$SCRATCH/pr-paths.json"
      [ "$count" -eq 100 ] || return 0
      page=$((page+1))
    done
    return 1
  fi
  response=$(ado_json "$ADO_BASE/pullRequests/$number/iterations?api-version=7.1") || return 1
  iteration=$(printf '%s' "$response" | jq -er '.value | map(.id) | max | select(type=="number" and .>0)') || return 1
  if cached=$(jq -ce --arg url "$url" --argjson number "$number" --argjson iteration "$iteration" '
    .sources[] | select(.kind=="pr" and .pr_id==$number and .url==$url
      and .iteration_id==$iteration and .measurement=="measured") |
    .paths | select(type=="array" and all(.[]; type=="string"))' "$SCRATCH/previous.json"); then
    printf '%s\n' "$cached" > "$SCRATCH/pr-paths.json"
    PR_ITERATION=$iteration
    return 0
  fi
  while [ "$page" -le 100 ]; do
    response=$(ado_json "$ADO_BASE/pullRequests/$number/iterations/$iteration/changes?compareTo=0&\$skip=$skip&\$top=$next_top&api-version=7.1") || return 1
    printf '%s' "$response" | jq -e '(.changeEntries|type)=="array" and all(.changeEntries[]; (.item.path|type)=="string")' >/dev/null || return 1
    jq --argjson response "$response" '. + [$response.changeEntries[] | select(.item.isFolder != true) |
      .item.path, .originalPath // empty | ltrimstr("/")] | unique' \
      "$SCRATCH/pr-paths.json" > "$SCRATCH/next.json"
    mv "$SCRATCH/next.json" "$SCRATCH/pr-paths.json"
    next_skip=$(printf '%s' "$response" | jq -er '.nextSkip // 0') || return 1
    next_top=$(printf '%s' "$response" | jq -er '.nextTop // 0') || return 1
    [[ "$next_skip" =~ ^[0-9]+$ && "$next_top" =~ ^[0-9]+$ ]] || return 1
    if [ "$next_top" -eq 0 ]; then PR_ITERATION=$iteration; return 0; fi
    [ "$next_skip" -gt "$skip" ] || return 1
    skip=$next_skip; page=$((page+1))
  done
  return 1
}

open_prs() {
  local page=1 skip=0 response count
  printf '[]\n' > "$SCRATCH/prs.json"
  while [ "$page" -le 100 ]; do
    if [ "$PROVIDER" = github ]; then
      response=$(gh_json "/repos/$REPOSITORY/pulls?state=open&per_page=100&page=$page") || return 1
      response=$(printf '%s' "$response" | jq -e 'select(type=="array") | map({pr_id:.number,url:.html_url,branch:.head.ref,status:"open"})') || return 1
    else
      response=$(ado_json "$ADO_BASE/pullRequests?searchCriteria.status=active&\$top=100&\$skip=$skip&api-version=7.1") || return 1
      response=$(printf '%s' "$response" | jq -e 'select((.value|type)=="array") | [.value[] |
        {pr_id:.pullRequestId,url:(.repository.webUrl+"/pullrequest/"+(.pullRequestId|tostring)),
        branch:(.sourceRefName|ltrimstr("refs/heads/")),status:"open"}]') || return 1
    fi
    printf '%s' "$response" | jq -e 'all(.[]; (.pr_id|type)=="number" and (.url|type)=="string" and (.branch|type)=="string")' >/dev/null || return 1
    count=$(printf '%s' "$response" | jq 'length')
    jq --argjson response "$response" '. + $response' "$SCRATCH/prs.json" > "$SCRATCH/next.json"
    mv "$SCRATCH/next.json" "$SCRATCH/prs.json"
    [ "$count" -eq 100 ] || return 0
    page=$((page+1)); skip=$((skip+100))
  done
  return 1
}

while IFS= read -r project_json; do
  project=$(printf '%s' "$project_json" | jq -r '.')
  case "$project" in ''|.|..|*/*|*$'\n'*|*$'\r'*) echo 'error: unsafe project name' >&2; exit 1 ;; esac
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  memory="$STATE/conflict-radar/$project.json"
  if [ -e "$memory" ]; then
    jq -e --arg project "$project" '.schema_version==1 and .project==$project and (.sources|type)=="array"' "$memory" >/dev/null || {
      printf 'error: malformed radar memory %s\n' "$memory" >&2; exit 1;
    }
    cp "$memory" "$SCRATCH/previous.json"
  else
    printf '{"sources":[]}\n' > "$SCRATCH/previous.json"
  fi
  jq --arg project "$project" '[.[] | select(.project==$project)]' "$SCRATCH/tasks.json" > "$SCRATCH/project-tasks.json"
  project_path=$(jq -r '.[0].project_path // empty' "$SCRATCH/project-tasks.json")
  [ -n "$project_path" ] || project_path=$(jq -r '.project_path // empty' "$SCRATCH/previous.json")
  [ -n "$project_path" ] || project_path="$FM_HOME/projects/$project"
  ledgers=$(bash "$SCRIPT_DIR/fm-project-mode.sh" --ledgers "$project")
  : > "$SCRATCH/sources.jsonl"
  : > "$SCRATCH/unmeasured.jsonl"
  origin=
  while IFS= read -r task; do
    worktree=$(printf '%s' "$task" | jq -r '.worktree')
    measurement=measured
    : > "$SCRATCH/paths.nul"
    base=$(radar_git "$worktree" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || measurement=unmeasured
    if [ "$measurement" = measured ]; then
      radar_git "$worktree" diff --no-ext-diff --no-textconv --no-renames --name-only -z "$base...HEAD" -- >> "$SCRATCH/paths.nul" 2>/dev/null || measurement=unmeasured
    fi
    radar_git "$worktree" diff --no-ext-diff --no-textconv --no-renames --name-only -z --cached HEAD -- >> "$SCRATCH/paths.nul" 2>/dev/null || measurement=unmeasured
    radar_git "$worktree" diff --no-ext-diff --no-textconv --no-renames --name-only -z -- >> "$SCRATCH/paths.nul" 2>/dev/null || measurement=unmeasured
    radar_git "$worktree" ls-files --others --exclude-standard -z >> "$SCRATCH/paths.nul" 2>/dev/null || measurement=unmeasured
    paths=$(jq -Rs 'split("\u0000") | map(select(length>0)) | unique' "$SCRATCH/paths.nul")
    task=$(printf '%s' "$task" | jq --argjson paths "$paths" --arg measurement "$measurement" --arg now "$now" \
      '. + {paths:$paths,measurement:$measurement,status:"tracked",observed_at:$now}')
    append_source "$task"
    [ "$measurement" = measured ] || unmeasured "$(printf '%s' "$task" | jq -r '.id'): worktree or base unreadable"
    if [ -z "$origin" ]; then
      origin=$(radar_git "$worktree" config --get remote.origin.url 2>/dev/null) || origin=
    fi
  done < <(jq -c '.[]' "$SCRATCH/project-tasks.json")
  if [ -z "$origin" ]; then
    origin=$(radar_git "$project_path" config --get remote.origin.url 2>/dev/null) || origin=
  fi
  forge_identity "$origin"
  forge_measured=false
  printf '[]\n' > "$SCRATCH/prs.json"
  if [ "$PROVIDER" = ado ] && ! FM_PR_ADO_TIMEOUT="$TIMEOUT" fm_pr_ado_token 2>/dev/null; then
    unmeasured 'forge: Azure token unavailable'
  elif [ "$PROVIDER" != none ] && open_prs; then
    forge_measured=true
  else
    unmeasured 'forge: origin unsupported/unreadable or open PR listing failed'
    [ -f "$SCRATCH/prs.json" ] || printf '[]\n' > "$SCRATCH/prs.json"
  fi
  while IFS= read -r pr; do
    number=$(printf '%s' "$pr" | jq -r '.pr_id')
    url=$(printf '%s' "$pr" | jq -r '.url')
    measurement=measured
    pr_files "$number" "$url" || measurement=unmeasured
    pr=$(printf '%s' "$pr" | jq --arg id "pr:$url" --arg measurement "$measurement" --arg now "$now" \
      --argjson iteration "${PR_ITERATION:-null}" --slurpfile paths "$SCRATCH/pr-paths.json" \
      '. + {id:$id,kind:"pr",paths:$paths[0],measurement:$measurement,observed_at:$now,iteration_id:$iteration}')
    append_source "$pr"
    [ "$measurement" = measured ] || unmeasured "pr:$url: changed files unreadable or pagination incomplete"
  done < <(jq -c '.[]' "$SCRATCH/prs.json")
  jq -s '.' "$SCRATCH/sources.jsonl" > "$SCRATCH/current.json"
  while IFS= read -r old_pr; do
    url=$(printf '%s' "$old_pr" | jq -r '.url')
    if jq -e --arg url "$url" 'any(.[]; .kind=="pr" and .url==$url)' "$SCRATCH/current.json" >/dev/null; then continue; fi
    state=unknown
    if [ "$forge_measured" = true ]; then
      number=$(printf '%s' "$old_pr" | jq -r '.pr_id')
      if [ "$PROVIDER" = github ]; then
        state=$(gh_json "/repos/$REPOSITORY/pulls/$number" | jq -er '.state | select(.=="closed" or .=="open")') || state=unknown
      else
        state=$(ado_json "$ADO_BASE/pullRequests/$number?api-version=7.1" | jq -er '.status | select(.=="completed" or .=="abandoned" or .=="active")') || state=unknown
      fi
    fi
    case "$state" in
      closed|completed|abandoned)
        jq -e --argjson old "$old_pr" 'any(.[]; .task_id as $id | ($old.task_ids // [] | index($id))!=null or .pr_url==$old.url or (.branch!="" and .branch==$old.branch))' \
          "$SCRATCH/project-tasks.json" >/dev/null || continue ;;
      *) unmeasured "pr:$url: previous PR completion unmeasured" ;;
    esac
    printf '%s' "$old_pr" | jq --arg state "$state" '.status=$state' >> "$SCRATCH/sources.jsonl"
  done < <(jq -c '.sources[] | select(.kind=="pr")' "$SCRATCH/previous.json")
  jq -s --slurpfile previous "$SCRATCH/previous.json" --slurpfile tasks "$SCRATCH/project-tasks.json" \
    --slurpfile unmeasured "$SCRATCH/unmeasured.jsonl" --arg project "$project" --arg project_path "$project_path" \
    --arg now "$now" --arg ledgers "$ledgers" '
    map(. as $source | ($previous[0].sources | map(select(.id==$source.id)) | .[0]) as $old |
      if .measurement=="unmeasured" and $old!=null then
        .paths=((.paths+$old.paths)|unique) | .observed_at=$old.observed_at
      else . end) |
    map(if .kind=="pr" then . as $pr | .task_ids=[$tasks[0][] |
      .task_id as $id | select(.pr_url==$pr.url or (.branch!="" and .branch==$pr.branch)
        or (($pr.task_ids // [] | index($id))!=null)) | .task_id] else . end) as $sources |
    ($ledgers | split(",") | map(select(length>0))) as $ledger_paths |
    def class($path):
      if ($ledger_paths|index($path))!=null or ($path|test("(?i)\\.(md|markdown|rst|adoc)$|(^|/)(readme|index|changelog|notes|verify|build-status)(\\.txt)?$")) then "ledger"
      elif ($path|test("(?i)\\.(csproj|fsproj|vbproj|lock|properties|ini|env)$|(^|/)(requirements|constraints)[^/]*\\.txt$|(^|/)(Directory\\.(Packages|Build)\\.props|packages\\.lock\\.json|package-lock\\.json|npm-shrinkwrap\\.json|global\\.json|package\\.json|pnpm-lock\\.yaml|\\.(env|editorconfig|npmrc|yarnrc))$")) then "mechanical"
      else "code" end;
    {schema_version:1,project:$project,project_path:$project_path,timestamp:$now,ledgers:$ledger_paths,
      sources:$sources,unmeasured:$unmeasured,
      matrix:([$sources[] | . as $source | .paths[] |
        {path:.,source:$source.id,participants:(if $source.kind=="pr" and ($source.task_ids|length)>0
          then [$source.task_ids[]|"task:"+.] else [$source.id] end)}] |
        group_by(.path) | map(.[0].path as $path | ([.[].participants[]]|unique) as $participants |
          {path:$path,class:class($path),sources:([.[].source]|unique),participants:$participants,shared:($participants|length>1)}))}
  ' "$SCRATCH/sources.jsonl" > "$SCRATCH/result.json"
  mkdir -p "$STATE/conflict-radar"
  temp_memory=$(mktemp "$STATE/conflict-radar/.matrix.XXXXXX")
  cp "$SCRATCH/result.json" "$temp_memory"
  mv "$temp_memory" "$memory"
  jq --slurpfile result "$SCRATCH/result.json" '. + $result' "$SCRATCH/projects.json" > "$SCRATCH/next.json"
  mv "$SCRATCH/next.json" "$SCRATCH/projects.json"
done < "$SCRATCH/names.jsonl"

if [ "$FORMAT" = json ]; then
  jq '{projects:.}' "$SCRATCH/projects.json"
else
  jq -r '.[] |
    .project as $project | .unmeasured[] as $issue | "\($project): unmeasured: \($issue)"' "$SCRATCH/projects.json"
  jq -r '.[] | .project as $project |
    [.matrix[]|select(.shared)] as $shared |
    if ($shared|length)>0 then $shared[] |
      "\($project): \(.class) \(.path|tojson) sources=\(.sources|join(","))"
    elif (.unmeasured|length)>0 then "\($project): overlap unmeasured (no measured shared paths)"
    else "\($project): no overlap" end' "$SCRATCH/projects.json"
  if [ "$(jq 'length' "$SCRATCH/projects.json")" -eq 0 ]; then echo 'no overlap (no project with multiple tracked ships)'; fi
fi
