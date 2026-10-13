#!/usr/bin/env bash
# Drives fm-pr-report-compact vendored ALONE (no sibling scripts) the way the
# Mosaiq.Factory re-vendor lane would: copy the single file into an empty
# tooling/ dir and run it. Compares base (bf552e2) vs target (dc12aea).
set -u
REPO=$1
FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
PY=$(python3 -c 'import sys; print(sys.executable)')
ATT='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"lint","status":"skipped"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
body() { printf '## Intent\n\nShip it.\n\n## What Changed\n\nFiles.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n%s\n' "$ATT"; }
for rev in bf552e2 dc12aea; do
  echo "================ revision $rev ================"
  T="$FIX/$rev/Factory/tooling"; mkdir -p "$T"
  git -C "$REPO" show "$rev:bin/fm-pr-report-compact" > "$T/fm-pr-report-compact"; chmod +x "$T/fm-pr-report-compact"
  echo "tooling/ contents: $(ls "$T")"
  # Minimal PATH: only python3 and a logging az stub (no bash, no siblings).
  MB="$FIX/$rev/minbin"; mkdir -p "$MB"; ln -s "$PY" "$MB/python3"
  printf '#!%s\nimport sys\nopen("%s","a").write(" ".join(sys.argv[1:])+"\\n")\nprint("{}")\n' "$PY" "$FIX/$rev/az.log" > "$MB/az"; chmod +x "$MB/az"
  cd "$FIX/$rev/Factory"
  echo "--- S1: --stdin --nm-skip lint (registered lint skip), normal PATH"
  body | tooling/fm-pr-report-compact --stdin --nm-skip lint > out1 2> err1; echo "exit=$?"; echo "stderr: $(cat err1)"; grep -E '^- ' out1
  echo "--- S2: --stdin with omitted/empty skip on a passed body"
  body | sed 's/"lint","status":"skipped"/"test","status":"completed"/' | tooling/fm-pr-report-compact --stdin --nm-skip '' > out2 2> err2; echo "exit=$?"; echo "stderr: $(cat err2)"; grep -E '^- ' out2
  echo "--- S3: invalid --nm-skip ci must exit 2, no body, owner diagnostic"
  body | tooling/fm-pr-report-compact --stdin --nm-skip ci > out3 2> err3; echo "exit=$? stdout_bytes=$(wc -c < out3)"; echo "stderr: $(cat err3)"
  echo "--- S4: minimal PATH (python3 only, no bash), isolated python -I -S, --nm-skip lint"
  body | env -i PATH="$MB" HOME="$FIX" "$PY" -I -S tooling/fm-pr-report-compact --stdin --nm-skip lint > out4 2> err4; echo "exit=$?"; echo "stderr: $(cat err4 | tail -2)"; grep -cE '^- ' out4 | sed 's/^/status lines: /'
  echo "--- S5: network form, invalid skip, minimal PATH: must exit 2 before any az call"
  env -i PATH="$MB" HOME="$FIX" tooling/fm-pr-report-compact https://dev.azure.com/x 1 --nm-skip review > /dev/null 2> err5; echo "exit=$?"; echo "stderr: $(cat err5 | tail -1)"; echo "az calls: $(cat ../az.log 2>/dev/null | wc -l)"
  echo "--- S6: network form, --nm-skip lint, minimal PATH: validation passes, reaches az"
  env -i PATH="$MB" HOME="$FIX" tooling/fm-pr-report-compact https://dev.azure.com/x 1 --nm-skip lint > /dev/null 2> err6; echo "exit=$?"; echo "stderr: $(cat err6 | tail -1)"; echo "az calls: $(cat ../az.log 2>/dev/null | wc -l)"; head -1 ../az.log 2>/dev/null
  cd - >/dev/null
done
