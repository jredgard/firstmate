#!/usr/bin/env bash
# Drives the real resolve-md-conflict.py CLI against the disposable fake dev.azure.com.
set -u
LAB=$1; WT=$2
NEW="$WT/.agents/skills/md-conflict-fastpath/resolve-md-conflict.py"
OLD="$LAB/old-resolve-md-conflict.py"
PORT=$(cat "$LAB/port")
export https_proxy="http://127.0.0.1:$PORT" SSL_CERT_FILE="$LAB/ca.pem" ADO_TOKEN=lab-token TMPDIR="$LAB/tmp"
unset ADO_ORG ADO_PROJECT FM_HOME no_proxy NO_PROXY
mkdir -p "$LAB/tmp"

mkhome() { # name repo origin
  local h="$LAB/$1"; mkdir -p "$h/projects/$2"; git init -q "$h/projects/$2"
  git -C "$h/projects/$2" remote add origin "$3"; echo "$h"; }

scen() { # prefix repo pr entries-json
  python3 - "$LAB" "$@" <<'PY'
import json, sys
lab, prefix, repo, pr, entries = sys.argv[1:]
json.dump({"prefix": prefix, "repo": repo, "pr": int(pr), "entries": json.loads(entries),
           "blobs": {"b": "# Notes\nbefore\n", "s": "# Notes\nPR fact: Redis\n", "t": "# Notes\ntarget fact: Service Bus\n"}},
          open(f"{lab}/scenario.json", "w"))
PY
  : > "$LAB/requests.log"; }

run() { # label, then command
  local label=$1; shift
  echo "### $label"
  echo "\$ $(printf '%q ' "$@" | sed "s#$LAB#\$LAB#g; s#$WT#\$WT#g")"
  "$@" > "$LAB/out" 2> "$LAB/err"; local rc=$?
  sed "s#$LAB#\$LAB#g" "$LAB/out"; sed "s#$LAB#\$LAB#g; s/^/[stderr] /" "$LAB/err"
  echo "[exit $rc]"
  echo "[requests seen by fake dev.azure.com]"; sed 's/^/  /' "$LAB/requests.log"; [ -s "$LAB/requests.log" ] || echo "  (none)"
  echo; : > "$LAB/requests.log"; }

DOC='[{"conflictId":11,"conflictPath":"/docs/NOTES.md","conflictType":"editEdit","resolutionStatus":"unresolved","baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}}]'
NULLST='[{"conflictId":11,"conflictPath":"/docs/NOTES.md","conflictType":"editEdit","resolutionStatus":null,"baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}}]'
MISSST='[{"conflictId":11,"conflictPath":"/docs/NOTES.md","conflictType":"editEdit","baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}}]'
TWO_NULL='[{"conflictId":11,"conflictPath":"/docs/NOTES.md","conflictType":"editEdit","resolutionStatus":"unresolved","baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}},{"conflictId":12,"conflictPath":"/README.md","conflictType":"editEdit","resolutionStatus":null,"baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}}]'
TWO_MISS='[{"conflictId":11,"conflictPath":"/docs/NOTES.md","conflictType":"editEdit","resolutionStatus":"unresolved","baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}},{"conflictId":12,"conflictPath":"/README.md","conflictType":"editEdit","baseBlob":{"objectId":"b"},"sourceBlob":{"objectId":"s"},"targetBlob":{"objectId":"t"}}]'
REPO=cLimsPoc.Evaluation
PREFIX=/tuvsud01/PS_clims-poc
printf '# Notes\nService Bus, Redis\n' > "$LAB/resolved.md"

CLIMS=$(mkhome home-clims-https $REPO "https://tuvsud01@dev.azure.com/tuvsud01/PS_clims-poc/_git/$REPO")
SCP=$(mkhome home-clims-scp $REPO "git@ssh.dev.azure.com:v3/tuvsud01/PS_clims-poc/$REPO")
SSHU=$(mkhome home-clims-sshurl $REPO "ssh://git@ssh.dev.azure.com/v3/tuvsud01/PS_clims-poc/$REPO")
GH=$(mkhome home-github $REPO "https://github.com/example/$REPO.git")
NOORIGIN=$(mkhome home-noorigin $REPO "https://x/y"); git -C "$NOORIGIN/projects/$REPO" remote remove origin

echo "======== S1: BEFORE (base 0a16d76f) — cLims home, no overrides ========"
scen $PREFIX $REPO 42 "$DOC"
run "base helper defaults to DS_mosaiq-poc" env FM_HOME="$CLIMS" python3 "$OLD" list $REPO 42
echo "======== S1: AFTER — cLims home (HTTPS origin), no overrides ========"
run "list derives tuvsud01/PS_clims-poc from origin" env FM_HOME="$CLIMS" python3 "$NEW" list $REPO 42

echo "======== S2: SSH origins ========"
run "scp-form origin" env FM_HOME="$SCP" python3 "$NEW" list $REPO 42
run "ssh:// URL origin" env FM_HOME="$SSHU" python3 "$NEW" list $REPO 42

echo "======== S3: apply end-to-end from derived cLims home ========"
scen $PREFIX $REPO 42 "$DOC"
run "apply resolves conflict 11 via derived routing" env FM_HOME="$CLIMS" python3 "$NEW" apply $REPO 42 11 "$LAB/resolved.md"
echo "patched content recorded by fake ADO: $(python3 -c "import json;print(repr(json.load(open('$LAB/scenario.json'))['patched_content']))")"; echo

echo "======== S4: per-axis overrides ========"
scen /tuvsud01/Override_proj $REPO 42 '[]'
run "ADO_PROJECT override, org derived" env FM_HOME="$CLIMS" ADO_PROJECT=Override_proj python3 "$NEW" list $REPO 42
scen /otherorg/PS_clims-poc $REPO 42 '[]'
run "ADO_ORG override, project derived" env FM_HOME="$CLIMS" ADO_ORG=https://dev.azure.com/otherorg python3 "$NEW" list $REPO 42
scen /otherorg/Both $REPO 42 '[]'
run "both overrides, no FM_HOME needed" env ADO_ORG=https://dev.azure.com/otherorg ADO_PROJECT=Both python3 "$NEW" list $REPO 42
scen "/tuvsud01/PS%20clims-poc" $REPO 42 '[]'
run "raw space in ADO_PROJECT override" env FM_HOME="$CLIMS" "ADO_PROJECT=PS clims-poc" python3 "$NEW" list $REPO 42
run "pre-encoded ADO_PROJECT override (no double encoding)" env FM_HOME="$CLIMS" "ADO_PROJECT=PS%20clims-poc" python3 "$NEW" list $REPO 42

echo "======== S5: refusal when derivation unavailable (adversarial) ========"
scen /tuvsud01/DS_mosaiq-poc $REPO 42 "$DOC"
run "FM_HOME unset" python3 "$NEW" list $REPO 42
run "FM_HOME unset, only ADO_ORG set" env ADO_ORG=https://dev.azure.com/tuvsud01 python3 "$NEW" list $REPO 42
run "repo missing from home" env FM_HOME="$CLIMS" python3 "$NEW" list OtherRepo 42
run "home repo has no origin" env FM_HOME="$NOORIGIN" python3 "$NEW" list $REPO 42
run "home repo origin is GitHub" env FM_HOME="$GH" python3 "$NEW" apply $REPO 42 11 "$LAB/resolved.md"

echo "======== S6: null / missing resolutionStatus in list ========"
scen $PREFIX $REPO 42 "$NULLST"
run "BEFORE: base helper, null status (ADO_ORG/PROJECT set)" env ADO_ORG=https://dev.azure.com/tuvsud01 ADO_PROJECT=PS_clims-poc python3 "$OLD" list $REPO 42
run "AFTER: null status" env FM_HOME="$CLIMS" python3 "$NEW" list $REPO 42
scen $PREFIX $REPO 42 "$MISSST"
run "BEFORE: base helper, missing status" env ADO_ORG=https://dev.azure.com/tuvsud01 ADO_PROJECT=PS_clims-poc python3 "$OLD" list $REPO 42
run "AFTER: missing status" env FM_HOME="$CLIMS" python3 "$NEW" list $REPO 42

echo "======== S7: null / missing status counted as remaining in apply ========"
scen $PREFIX $REPO 42 "$TWO_NULL"
run "apply 11 while 12 has null status" env FM_HOME="$CLIMS" python3 "$NEW" apply $REPO 42 11 "$LAB/resolved.md"
scen $PREFIX $REPO 42 "$TWO_MISS"
run "apply 11 while 12 has no status key" env FM_HOME="$CLIMS" python3 "$NEW" apply $REPO 42 11 "$LAB/resolved.md"

echo "======== S8: usage text ========"
run "no arguments prints usage" python3 "$NEW"
