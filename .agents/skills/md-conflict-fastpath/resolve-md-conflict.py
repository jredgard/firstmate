#!/usr/bin/env python3
"""List or resolve documentation-only Azure DevOps PR conflicts on the forge.

Owner: .agents/skills/md-conflict-fastpath/SKILL.md.
Path classification taxonomy owner: bin/fm-conflict-radar.sh; this helper mirrors
its documentation text basenames and dependency text manifests alongside the
approved .NET package/lock and simple key-value settings subset for tier 4.
GET pullRequests/{prId}/conflicts?includeObsolete=false lists conflicts;
GET blobs/{objectId} retrieves the base, source and target bytes;
PATCH pullRequests/{prId}/conflicts/{conflictId} submits a UserMerged resolution;
the JSON body uses mergeType="userMerged", resolutionStatus="resolved" and
userMergedContent as an array of file bytes.
GET pullRequests/{prId} records lastMergeCommit before PATCH and polls mergeStatus
only after re-listing conflicts confirms no unresolved entries remain.
An unchanged conflicts status may be stale; poll at most 30 times, two seconds apart.
The conflicts API uses api-version=7.1-preview.1; blobs and PR reads use 7.1.

usage: resolve-md-conflict.py list  <repo> <prId>
       resolve-md-conflict.py apply <repo> <prId> <conflictId> <resolvedFile>
env:   FM_HOME derives organization and project from projects/<repo>'s origin.
       ADO_ORG (full base URL) and ADO_PROJECT override their respective axes;
       missing overrides require a home origin in Azure DevOps HTTPS or SSH form.
       ADO_TOKEN, otherwise az account get-access-token --resource
       499b84ac-1321-427f-aa17-267ca6975798 --query accessToken --output tsv.
list exits: 0 no conflicts or doc-only candidates, 1 mechanical candidates, 2 code/non-editEdit.
apply exits: 0 merge succeeded, 1 unresolved conflicts remain, 3 resolution/merge
failed, 4 merge result still pending after bounded polling.
Both commands exit 5 for usage, home derivation, authentication, REST, malformed
response, file I/O or subprocess errors, with a concise diagnostic on stderr.
Classification is a path hint only; the owner skill requires inspecting use and hunks.
"""
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

API = "api-version=7.1-preview.1"
DOC_EXT = (".md", ".markdown", ".rst", ".adoc")
DOC_TEXT_NAMES = ("readme.txt", "index.txt", "changelog.txt", "notes.txt", "verify.txt", "build-status.txt")
MECH_EXT = (".csproj", ".lock", ".properties", ".ini", ".env")
MECH_NAMES = ("directory.packages.props", "directory.build.props", "global.json", "packages.lock.json",
              ".env", ".editorconfig", ".npmrc", ".yarnrc")


def token():
    access_token = os.environ.get("ADO_TOKEN") or subprocess.check_output(
        ["az", "account", "get-access-token", "--resource",
         "499b84ac-1321-427f-aa17-267ca6975798", "--query", "accessToken", "--output", "tsv"],
        text=True, stderr=subprocess.PIPE,
    ).strip()
    if not access_token:
        raise ValueError("Azure CLI returned an empty access token")
    return access_token


def req(url, method="GET", body=None, raw=False):
    request = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + token()})
    if body is not None:
        request.add_header("Content-Type", "application/json")
        request.data = json.dumps(body).encode()
    with urllib.request.urlopen(request) as response:
        data = response.read()
    if raw:
        return data
    response = json.loads(data)
    if not isinstance(response, dict):
        raise ValueError("REST response must be a JSON object")
    if response.get("mergeStatus") is not None and not isinstance(response["mergeStatus"], str):
        raise ValueError("PR mergeStatus must be a string")
    merge_commit = response.get("lastMergeCommit")
    if merge_commit is not None and (
        not isinstance(merge_commit, dict)
        or (merge_commit.get("commitId") is not None and not isinstance(merge_commit["commitId"], str))
    ):
        raise ValueError("PR lastMergeCommit must be an object with a string commitId")
    return response


def ado_location(repo):
    organization = os.environ.get("ADO_ORG")
    project = os.environ.get("ADO_PROJECT")
    if organization and project:
        return organization, project
    override_hint = "; set ADO_ORG and ADO_PROJECT explicitly"
    home = os.environ.get("FM_HOME")
    if not home:
        raise ValueError("FM_HOME is unset" + override_hint)
    repository = Path(home) / "projects" / repo
    if not repository.is_dir():
        raise ValueError(f"repository directory is missing: {repository}" + override_hint)
    try:
        origin = subprocess.check_output(
            ["git", "-C", str(repository), "remote", "get-url", "origin"],
            text=True, stderr=subprocess.PIPE,
        ).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f"origin is unavailable for {repository}" + override_hint) from error
    match = re.fullmatch(
        r"(?:git@ssh\.dev\.azure\.com:v3|ssh://git@ssh\.dev\.azure\.com/v3)/([^/]+)/([^/]+)/[^/]+/?",
        origin,
    )
    if not match:
        try:
            remote = urlsplit(origin)
        except ValueError:
            remote = None
        if remote and remote.scheme == "https" and remote.hostname == "dev.azure.com":
            match = re.fullmatch(r"/([^/]+)/([^/]+)/_git/[^/]+/?", remote.path)
    if not match:
        raise ValueError(f"origin is not a supported Azure DevOps URL for {repository}" + override_hint)
    return organization or f"https://dev.azure.com/{match[1]}", project or unquote(match[2])


def base(repo):
    organization, project = ado_location(repo)
    return f"{organization}/{quote(project, safe='')}/_apis/git/repositories/{repo}"


def conflicts(repo, pr):
    entries = req(f"{base(repo)}/pullRequests/{pr}/conflicts?{API}&includeObsolete=false")["value"]
    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
        raise ValueError("conflicts response value must be an array of objects")
    for entry in entries:
        status = entry.get("resolutionStatus")
        if status is None:
            entry["resolutionStatus"] = "unresolved"
        elif not isinstance(status, str):
            raise ValueError("conflict resolutionStatus must be a string or null")
    return entries


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
        filename = path.rsplit("/", 1)[-1].lower()
        conflict_type = conflict["conflictType"]
        doc = conflict_type == "editEdit" and (path.lower().endswith(DOC_EXT) or filename in DOC_TEXT_NAMES)
        mechanical = conflict_type == "editEdit" and (
            path.lower().endswith(MECH_EXT) or filename in MECH_NAMES
            or (filename.startswith(("requirements", "constraints")) and filename.endswith(".txt"))
        )
        doc_only &= doc
        mechanical_only &= doc or mechanical
        kind = "doc" if doc else ("mechanical" if mechanical else "CODE")
        print(f"conflict {conflict['conflictId']} {conflict_type} {path} status={conflict.get('resolutionStatus')} class={kind}")
        if not (doc or mechanical) or filename == "packages.lock.json" or path.lower().endswith(".lock"):
            continue
        directory = Path(tempfile.mkdtemp(prefix="mdconflict-"))
        for side in ("base", "source", "target"):
            (directory / side).write_bytes(blob(repo, conflict[side + "Blob"]["objectId"]))
        merge = subprocess.run(
            ["git", "merge-file", "-p", "-L", "PR branch", "-L", "base", "-L", "target branch",
             str(directory / "source"), str(directory / "base"), str(directory / "target")],
            capture_output=True, text=True,
        )
        if merge.returncode < 0 or merge.returncode > 127:
            raise subprocess.CalledProcessError(merge.returncode, merge.args, stderr=merge.stderr)
        (directory / "three-way").write_text(merge.stdout)
        print(f"  files: {directory}/base {directory}/source {directory}/target  three-way (with markers): {directory}/three-way")
        lines = merge.stdout.splitlines()
        line_index = 0
        while line_index < len(lines):
            if lines[line_index].startswith("<<<<<<<"):
                end_index = line_index
                while end_index < len(lines) and not lines[end_index].startswith(">>>>>>>"):
                    end_index += 1
                print("  hunk at line", line_index + 1)
                for line in lines[line_index:end_index + 1]:
                    print("   ", line)
                line_index = end_index
            line_index += 1
    if doc_only:
        print("verdict: doc-only candidate, eligible for forge-side resolution (tier 1) after verifying no code or tooling reads these files")
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
    pull_request_url = f"{base(repo)}/pullRequests/{pr}?api-version=7.1"
    previous_merge_commit = (req(pull_request_url).get("lastMergeCommit") or {}).get("commitId")
    response = req(f"{base(repo)}/pullRequests/{pr}/conflicts/{conflict_id}?{API}", "PATCH", body)
    if not isinstance(response["resolutionStatus"], str):
        raise ValueError("resolution response resolutionStatus must be a string")
    print("resolution:", response.get("resolutionStatus"), response.get("resolutionError"))
    if response.get("resolutionStatus") != "resolved" or response.get("resolutionError") not in (None, 0, "none"):
        return 3
    remaining = sum(conflict.get("resolutionStatus") != "resolved" for conflict in conflicts(repo, pr))
    if remaining:
        print(f"{remaining} conflicts remaining")
        return 1
    for attempt in range(30):
        pull_request = req(pull_request_url)
        merge_status = pull_request.get("mergeStatus")
        merge_commit = (pull_request.get("lastMergeCommit") or {}).get("commitId")
        stale_conflicts = merge_status == "conflicts" and (not merge_commit or merge_commit == previous_merge_commit)
        if merge_status not in ("queued", "notSet", None) and not stale_conflicts:
            print("mergeStatus:", merge_status, "lastMergeCommit:", (merge_commit or "")[:8])
            return 0 if merge_status == "succeeded" else 3
        if attempt < 29:
            time.sleep(2)
    print("mergeStatus still pending")
    return 4


if __name__ == "__main__":
    arguments = sys.argv[1:]
    try:
        if len(arguments) == 3 and arguments[0] == "list":
            sys.exit(cmd_list(arguments[1], arguments[2]))
        if len(arguments) == 5 and arguments[0] == "apply":
            sys.exit(cmd_apply(arguments[1], arguments[2], arguments[3], arguments[4]))
        print(__doc__)
        raise ValueError("expected list <repo> <prId> or apply <repo> <prId> <conflictId> <resolvedFile>")
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            subprocess.SubprocessError, http.client.HTTPException) as error:
        diagnostic = ' '.join(str(error).splitlines())
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail = next((line.strip() for line in error.stderr.splitlines() if line.strip()), "")
            if detail:
                diagnostic += f": {detail}"
        access_token = os.environ.get("ADO_TOKEN")
        if access_token:
            diagnostic = diagnostic.replace(access_token, "[REDACTED]")
        diagnostic = re.sub(r"(?i)\bbearer\s+\S+", "Bearer [REDACTED]", diagnostic)
        print(f"error: {type(error).__name__}: {diagnostic}", file=sys.stderr)
        sys.exit(5)
