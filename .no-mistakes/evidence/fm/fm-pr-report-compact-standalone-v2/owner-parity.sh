#!/usr/bin/env bash
# Compares bin/fm-dod-lib.sh fm_nm_skip_valid (owner) with the standalone tool
# on a valid attested body: exit status class and stderr diagnostic.
. bin/fm-dod-lib.sh
ATT='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
body=$(printf '## Intent\n\nShip it.\n\n## Pipeline\n\n%s\n' "$ATT")
for v in '' lint ci review 'lint,ci' 'lint,' Lint ' lint' $'lint\n' $'\tlint'; do
  od=$(fm_nm_skip_valid "$v" fm-pr-report-compact 2>&1 >/dev/null); orc=$?
  td=$(printf '%s' "$body" | bin/fm-pr-report-compact --stdin --nm-skip "$v" 2>&1 >/dev/null); trc=$?
  [ "$od" = "$td" ] && s=same-stderr || s=DIFF
  printf '%-12q owner_rc=%s tool_rc=%s %s\n' "$v" "$orc" "$trc" "$s"
done
