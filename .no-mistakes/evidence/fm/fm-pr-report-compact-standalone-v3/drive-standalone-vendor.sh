#!/usr/bin/env bash
# Live driver: vendor fm-pr-report-compact ALONE into a disposable Factory-style
# tooling/ dir (no fm-dod-lib.sh) and drive its public CLI.
set -u
WT=$1        # gate worktree
OUT=$2       # transcript file
PY=/usr/bin/python3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-vendor-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
exec > >(tee "$OUT") 2>&1

mkdir -p "$LAB/factory/tooling" "$LAB/base/tooling" "$LAB/bin"
git -C "$WT" show HEAD:bin/fm-pr-report-compact > "$LAB/factory/tooling/fm-pr-report-compact"
git -C "$WT" show 3db82013099a937d89b49f3d51e24a37f7d85a85:bin/fm-pr-report-compact > "$LAB/base/tooling/fm-pr-report-compact"
chmod +x "$LAB"/*/tooling/fm-pr-report-compact
ln -s "$PY" "$LAB/bin/python3"   # PATH holds python3 ONLY (no bash, no az)

ATT='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"d4aeca250cf6e5927915d23a55a7b51c2aac2d34","steps":[{"step":"intent","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"lint","status":"skipped"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
ATT_PLAIN=${ATT/'{"step":"lint","status":"skipped"},'/}
body() { printf '## What Changed\n\nFiles.\n\n## Intent\n\nShip it.\n\n## Risk Assessment\n\nLow.\n\n## Pipeline\n\n%s\n' "$1"; }

run() {  # <label> <tool> <attestation> <nm-skip...>
  local label=$1 tool=$2 att=$3; shift 3
  echo "=== $label"
  echo "\$ ls $(dirname "$tool")"; ls "$(dirname "$tool")"
  echo "\$ env -i PATH=$LAB/bin HOME=$LAB python3 -I -S $tool --stdin $*"
  body "$att" | env -i PATH="$LAB/bin" HOME="$LAB" "$PY" -I -S -c '
import sys, runpy
spawned = []
def hook(ev, args):
    if ev in ("subprocess.Popen", "os.posix_spawn", "os.exec", "os.system", "os.fork"):
        spawned.append((ev, args[:2] if isinstance(args, tuple) else args))
sys.addaudithook(hook)
tool = sys.argv[1]; sys.argv = sys.argv[1:]
try:
    runpy.run_path(tool, run_name="__main__")
    code = 0
except SystemExit as e:
    code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
nonstd = sorted({m.split(".")[0] for m in sys.modules} - set(sys.stdlib_module_names) - set(sys.builtin_module_names) - {"__main__", "__mp_main__"})
print(f"[audit] exit={code} child_processes={spawned} non_stdlib_modules={nonstd}", file=sys.stderr)
sys.exit(code)
' "$tool" --stdin "$@"
  echo "[shell] exit=$?"
  echo
}

echo "##### HEAD (target 33b2ad7) vendored alone"
run "S1 omitted --nm-skip, all passed"      "$LAB/factory/tooling/fm-pr-report-compact" "$ATT_PLAIN"
run "S1 --nm-skip '' , all passed"          "$LAB/factory/tooling/fm-pr-report-compact" "$ATT_PLAIN" --nm-skip ''
run "S1 --nm-skip lint, attested lint skip" "$LAB/factory/tooling/fm-pr-report-compact" "$ATT" --nm-skip lint
for bad in ci review 'lint,ci' Lint ' lint' 'lint ' $'lint\n' "lint'; touch $LAB/pwned; echo '"; do
  run "S2 invalid --nm-skip $(printf %q "$bad")" "$LAB/factory/tooling/fm-pr-report-compact" "$ATT" --nm-skip "$bad"
done
[ -e "$LAB/pwned" ] && echo "!!! injection side effect present" || echo "[check] no injection side effect file"
echo
echo "##### BASE (3db8201) vendored alone - regression reproduction"
run "S3 base --nm-skip lint"                "$LAB/base/tooling/fm-pr-report-compact" "$ATT" --nm-skip lint
run "S3 base omitted --nm-skip"             "$LAB/base/tooling/fm-pr-report-compact" "$ATT_PLAIN"
