#!/usr/bin/env python3
"""List or resolve documentation-only Azure DevOps PR conflicts on the forge.

Owner: .agents/skills/md-conflict-fastpath/SKILL.md.
GET pullRequests/{prId}/conflicts?includeObsolete=false lists conflicts;
GET blobs/{objectId} retrieves the base, source and target bytes;
PATCH pullRequests/{prId}/conflicts/{conflictId} submits a UserMerged resolution;
GET pullRequests/{prId} polls mergeStatus after applying it.
The conflicts API uses api-version=7.1-preview.1; blobs and PR reads use 7.1.

usage: resolve-md-conflict.py list  <repo> <prId>
       resolve-md-conflict.py apply <repo> <prId> <conflictId> <resolvedFile>
env:   ADO_ORG (default https://dev.azure.com/tuvsud01), ADO_PROJECT (default DS_mosaiq-poc),
       ADO_TOKEN, otherwise az account get-access-token --resource
       499b84ac-1321-427f-aa17-267ca6975798 --query accessToken --output tsv.
list exits: 0 no conflicts or doc-only, 1 mechanical candidates, 2 code/non-editEdit.
Classification is a path hint only; the owner skill requires inspecting use and hunks.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ORG = os.environ.get("ADO_ORG", "https://dev.azure.com/tuvsud01")
PROJ = os.environ.get("ADO_PROJECT", "DS_mosaiq-poc")
API = "api-version=7.1-preview.1"
DOC_EXT = (".md", ".markdown", ".rst", ".txt", ".adoc")
MECH_EXT = (".csproj", ".props", ".targets", "packages.lock.json", ".lock", "global.json", ".editorconfig", ".runsettings")


def token():
    return os.environ.get("ADO_TOKEN") or subprocess.check_output(
        ["az", "account", "get-access-token", "--resource",
         "499b84ac-1321-427f-aa17-267ca6975798", "--query", "accessToken", "--output", "tsv"],
        text=True,
    ).strip()


def req(url, method="GET", body=None, raw=False):
    request = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + token()})
    if body is not None:
        request.add_header("Content-Type", "application/json")
        request.data = json.dumps(body).encode()
    with urllib.request.urlopen(request) as response:
        data = response.read()
    return data if raw else json.loads(data)


def base(repo):
    return f"{ORG}/{PROJ}/_apis/git/repositories/{repo}"


def conflicts(repo, pr):
    return req(f"{base(repo)}/pullRequests/{pr}/conflicts?{API}&includeObsolete=false")["value"]


def blob(repo, object_id):
    return req(f"{base(repo)}/blobs/{object_id}?api-version=7.1&$format=octetStream", raw=True)


def cmd_list(repo, pr):
    entries = conflicts(repo, pr)
    if not entries:
        print("no conflicts")
        return 0
    doc_only = True
    mechanical_only = True
    for conflict in entries:
        path = conflict["conflictPath"]
        conflict_type = conflict["conflictType"]
        doc = conflict_type == "editEdit" and path.lower().endswith(DOC_EXT)
        mechanical = conflict_type == "editEdit" and path.lower().endswith(MECH_EXT)
        doc_only &= doc
        mechanical_only &= doc or mechanical
        kind = "doc" if doc else ("mechanical" if mechanical else "CODE")
        print(f"conflict {conflict['conflictId']} {conflict_type} {path} status={conflict.get('resolutionStatus')} class={kind}")
        if not (doc or mechanical) or path.lower().endswith(("packages.lock.json", ".lock")):
            continue
        directory = Path(tempfile.mkdtemp(prefix="mdconflict-"))
        for side in ("base", "source", "target"):
            (directory / side).write_bytes(blob(repo, conflict[side + "Blob"]["objectId"]))
        merge = subprocess.run(
            ["git", "merge-file", "-p", "-L", "PR branch", "-L", "base", "-L", "target branch",
             str(directory / "source"), str(directory / "base"), str(directory / "target")],
            capture_output=True, text=True,
        )
        (directory / "three-way").write_text(merge.stdout)
        print(f"  files: {directory}/base {directory}/source {directory}/target  three-way (with markers): {directory}/three-way")
        lines = merge.stdout.splitlines()
        line_index = 0
        while line_index < len(lines):
            if lines[line_index].startswith("<<<<<<<"):
                end_index = line_index
                while not lines[end_index].startswith(">>>>>>>"):
                    end_index += 1
                print("  hunk at line", line_index + 1)
                for line in lines[line_index:end_index + 1]:
                    print("   ", line)
                line_index = end_index
            line_index += 1
    if doc_only:
        print("verdict: doc-only, eligible for forge-side resolution (tier 1)")
        return 0
    if mechanical_only:
        print("verdict: mechanical (package/lock/config lines), eligible for the skip-test,document rerun (tier 4) if the hunks hold no code")
        return 1
    print("verdict: CODE conflict, use the ordinary branch-sync procedure and full validation")
    return 2


def cmd_apply(repo, pr, conflict_id, path):
    content = list(Path(path).read_bytes())
    body = {"conflictId": int(conflict_id), "conflictType": "editEdit", "resolutionStatus": "resolved",
            "resolution": {"mergeType": "userMerged", "userMergedContent": content}}
    response = req(f"{base(repo)}/pullRequests/{pr}/conflicts/{conflict_id}?{API}", "PATCH", body)
    print("resolution:", response.get("resolutionStatus"), response.get("resolutionError"))
    for _ in range(30):
        pull_request = req(f"{base(repo)}/pullRequests/{pr}?api-version=7.1")
        merge_status = pull_request.get("mergeStatus")
        if merge_status not in ("queued", "notSet", None):
            print("mergeStatus:", merge_status, "lastMergeCommit:", (pull_request.get("lastMergeCommit") or {}).get("commitId", "")[:8])
            return 0 if merge_status == "succeeded" else 3
        time.sleep(2)
    print("mergeStatus still pending")
    return 4


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if len(arguments) == 3 and arguments[0] == "list":
        sys.exit(cmd_list(arguments[1], arguments[2]))
    if len(arguments) == 5 and arguments[0] == "apply":
        sys.exit(cmd_apply(arguments[1], arguments[2], arguments[3], arguments[4]))
    print(__doc__)
    sys.exit(1)
