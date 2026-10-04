#!/usr/bin/env bash
# Offline CLI regressions for md-conflict-fastpath classification and REST output.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 - "$ROOT/.agents/skills/md-conflict-fastpath/resolve-md-conflict.py" <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HELPER = sys.argv.pop()


class ConflictCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="md-fastpath-test-")
        cls.root = Path(cls.temporary.name)
        cls.fakebin = cls.root / "bin"
        cls.fakebin.mkdir()
        az = cls.fakebin / "az"
        az.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$AZ_ARGS"\n'
                      'if [ "${AZ_EXIT:-0}" != 0 ]; then printf "%s\\n" "${AZ_ERROR-token failed}" >&2; '
                      'printf "%s\\n" "${AZ_TOKEN-stub-token}"; exit "$AZ_EXIT"; fi\n'
                      'printf "%s\\n" "${AZ_TOKEN-stub-token}"\n')
        az.chmod(0o700)
        cls.entries = []
        cls.requests = []
        cls.blobs = {"base": b"before\n", "source": b"source fact\n", "target": b"target fact\n"}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_arguments):
                pass

            def do_GET(self):
                route = urlsplit(self.path)
                query = parse_qs(route.query)
                cls.requests.append(("GET", route.path, query, self.headers.get("Authorization"), None))
                if self.inject_response():
                    return
                if route.path == f"{cls.route_prefix}/_apis/git/repositories/repo/pullRequests/7/conflicts":
                    self.reply(json.dumps({"count": len(cls.entries), "value": cls.entries}).encode())
                elif route.path.startswith(f"{cls.route_prefix}/_apis/git/repositories/repo/blobs/"):
                    self.reply(cls.blobs[route.path.rsplit("/", 1)[1]])
                elif route.path == f"{cls.route_prefix}/_apis/git/repositories/repo/pullRequests/7":
                    pull_request = cls.pull_requests[0]
                    if len(cls.pull_requests) > 1:
                        cls.pull_requests.pop(0)
                    self.reply(json.dumps(pull_request).encode())
                else:
                    self.send_error(404)

            def do_PATCH(self):
                route = urlsplit(self.path)
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                cls.requests.append(("PATCH", route.path, parse_qs(route.query),
                                     self.headers.get("Authorization"), payload))
                if self.inject_response():
                    return
                if route.path == f"{cls.route_prefix}/_apis/git/repositories/repo/pullRequests/7/conflicts/{payload['conflictId']}":
                    if cls.resolution["resolutionStatus"] == "resolved" and cls.resolution.get("resolutionError") in (None, 0, "none"):
                        for entry in cls.entries:
                            if entry["conflictId"] == payload["conflictId"]:
                                entry["resolutionStatus"] = "resolved"
                    self.reply(json.dumps(cls.resolution).encode())
                else:
                    self.send_error(404)

            def reply(self, content):
                self.send_response(200)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            def inject_response(self):
                if len(cls.requests) != cls.override_request:
                    return False
                if cls.override_status:
                    self.send_error(cls.override_status)
                else:
                    self.reply(cls.override_body)
                return True

        cls.server = HTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temporary.cleanup()

    def setUp(self):
        type(self).route_prefix = "/fixture"
        type(self).requests = []
        type(self).entries = []
        type(self).blobs = {"base": b"before\n", "source": b"source fact\n", "target": b"target fact\n"}
        type(self).resolution = {"resolutionStatus": "resolved", "resolutionError": None}
        type(self).pull_requests = [{"mergeStatus": "succeeded", "lastMergeCommit": {"commitId": "0123456789abcdef"}}]
        type(self).override_request = None
        type(self).override_status = None
        type(self).override_body = b"{}"
        self.environment = os.environ.copy()
        self.environment.pop("FM_HOME", None)
        self.environment.update({
            "ADO_ORG": f"http://127.0.0.1:{self.server.server_port}",
            "ADO_PROJECT": "fixture",
            "ADO_TOKEN": "stub-token",
            "PATH": str(self.fakebin) + os.pathsep + self.environment["PATH"],
            "AZ_ARGS": str(self.root / "az-arguments"),
            "TMPDIR": str(self.root),
        })

    def invoke(self, *arguments, fast_poll=False, redirect_ado=False, error=False):
        server_url = f"http://127.0.0.1:{self.server.server_port}"
        command = [sys.executable, "-c",
                   "import runpy, sys, urllib.request; from contextlib import nullcontext; "
                   "from unittest.mock import patch\n"
                   "original_urlopen = urllib.request.urlopen\n"
                   "def offline_urlopen(request):\n"
                   f"    if {redirect_ado!r}:\n"
                   "        assert request.full_url.startswith('https://dev.azure.com/'), request.full_url\n"
                   f"        request.full_url = request.full_url.replace('https://dev.azure.com', {server_url!r}, 1)\n"
                   f"    assert request.full_url.startswith({server_url + '/'!r}), request.full_url\n"
                   "    return original_urlopen(request)\n"
                   "sys.argv = sys.argv[1:]\n"
                   "with patch('urllib.request.urlopen', offline_urlopen), "
                   f"patch('time.sleep') if {fast_poll!r} else nullcontext():\n"
                   "    runpy.run_path(sys.argv[0], run_name='__main__')",
                   HELPER, *arguments]
        result = subprocess.run(command, env=self.environment,
                                capture_output=True, text=True, timeout=10)
        if error:
            self.assertEqual(result.returncode, 5)
            self.assertTrue(result.stderr.startswith("error: "), result.stderr)
            self.assertEqual(len(result.stderr.splitlines()), 1)
            self.assertNotIn("Traceback", result.stderr)
        else:
            self.assertEqual(result.stderr, "")
        for request in self.requests:
            self.assertEqual(request[3], "Bearer stub-token")
        return result

    def list_conflicts(self, paths, conflict_type="editEdit"):
        type(self).requests = []
        type(self).entries = [
            {"conflictId": conflict_id, "conflictPath": path, "conflictType": conflict_type,
             "resolutionStatus": "unresolved", "baseBlob": {"objectId": "base"},
             "sourceBlob": {"objectId": "source"}, "targetBlob": {"objectId": "target"}}
            for conflict_id, path in enumerate(paths, 1)
        ]
        return self.invoke("list", "repo", "7")

    def home_origin(self, origin):
        home = Path(tempfile.mkdtemp(prefix="home-", dir=self.root))
        repository = home / "projects" / "repo"
        repository.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(repository)], env=self.environment, check=True,
                       capture_output=True, text=True)
        subprocess.run(["git", "-C", str(repository), "remote", "add", "origin", origin],
                       env=self.environment, check=True, capture_output=True, text=True)
        self.environment["FM_HOME"] = str(home)
        return repository

    def test_home_derives_non_mosaiq_organization_and_project(self):
        for origin, project in (
            ("https://dev.azure.com/climsorg/PS_clims-poc/_git/repo", "PS_clims-poc"),
            ("https://climsorg@dev.azure.com/climsorg/PS_clims-poc/_git/repo", "PS_clims-poc"),
            ("git@ssh.dev.azure.com:v3/climsorg/PS_clims-poc/repo", "PS_clims-poc"),
            ("https://dev.azure.com/climsorg/PS%20clims-poc/_git/repo", "PS%20clims-poc"),
            ("git@ssh.dev.azure.com:v3/climsorg/PS%20clims-poc/repo", "PS%20clims-poc"),
        ):
            with self.subTest(origin=origin):
                self.home_origin(origin)
                self.environment.pop("ADO_ORG", None)
                self.environment.pop("ADO_PROJECT", None)
                type(self).requests = []
                type(self).route_prefix = f"/climsorg/{project}"
                result = self.invoke("list", "repo", "7", redirect_ado=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "no conflicts\n")
                self.assertEqual(len(self.requests), 1)
                self.assertEqual(self.requests[0][1],
                                 f"/climsorg/{project}/_apis/git/repositories/repo/pullRequests/7/conflicts")

    def test_environment_overrides_win_per_axis(self):
        self.home_origin("https://climsorg@dev.azure.com/climsorg/PS_clims-poc/_git/repo")
        for override_org, override_project, prefix in (
            (True, True, "/fixture"), (True, False, "/PS_clims-poc"),
            (False, True, "/climsorg/fixture"),
        ):
            with self.subTest(override_org=override_org, override_project=override_project):
                self.environment["ADO_ORG"] = f"http://127.0.0.1:{self.server.server_port}"
                self.environment["ADO_PROJECT"] = "fixture"
                if not override_org:
                    self.environment.pop("ADO_ORG")
                if not override_project:
                    self.environment.pop("ADO_PROJECT")
                type(self).requests = []
                type(self).route_prefix = prefix
                result = self.invoke("list", "repo", "7", redirect_ado=not override_org)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(self.requests[0][1],
                                 f"{prefix}/_apis/git/repositories/repo/pullRequests/7/conflicts")

    def test_home_derivation_refuses_before_rest_when_unavailable(self):
        for missing, origin in (
            ("FM_HOME", None), ("projects/repo", None), ("origin", None),
            ("Azure DevOps", "https://github.com/example/repo.git"),
            ("Azure DevOps", "https://dev.azure.com/climsorg/repo"),
            ("Azure DevOps", "https://[invalid/repo"),
        ):
            for overrides in ((), ("ADO_ORG",), ("ADO_PROJECT",)):
                with self.subTest(missing=missing, overrides=overrides):
                    self.environment.pop("FM_HOME", None)
                    self.environment.pop("ADO_ORG", None)
                    self.environment.pop("ADO_PROJECT", None)
                    for override in overrides:
                        self.environment[override] = "fixture"
                    if missing == "projects/repo":
                        self.environment["FM_HOME"] = str(self.root / "absent-home")
                    elif missing in ("Azure DevOps", "origin"):
                        repository = self.home_origin(origin or "https://github.com/example/repo.git")
                        if missing == "origin":
                            subprocess.run(["git", "-C", str(repository), "remote", "remove", "origin"],
                                           env=self.environment, check=True, capture_output=True, text=True)
                    result = self.invoke("list", "repo", "7", error=True)
                    self.assertIn(missing, result.stderr)
                    self.assertIn("ADO_ORG", result.stderr)
                    self.assertIn("ADO_PROJECT", result.stderr)
                    self.assertEqual(self.requests, [])

    def test_complete_overrides_need_no_home_and_import_is_lazy(self):
        self.home_origin("https://github.com/example/repo.git")
        result = self.invoke("list", "repo", "7")
        self.assertEqual(result.returncode, 0)
        self.environment.pop("FM_HOME")
        self.environment.pop("ADO_ORG")
        result = subprocess.run([sys.executable, "-c", "import runpy, sys; runpy.run_path(sys.argv[1])", HELPER],
                                env=self.environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")

    def test_null_and_missing_conflict_status_are_unresolved(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.list_conflicts(["/README.md"])
                type(self).requests = []
                if missing:
                    self.entries[0].pop("resolutionStatus")
                else:
                    self.entries[0]["resolutionStatus"] = None
                result = self.invoke("list", "repo", "7")
                self.assertEqual(result.returncode, 0)
                self.assertIn("status=unresolved class=doc\n", result.stdout)
                self.assertEqual(len(self.requests), 4)

    def test_non_string_non_null_conflict_status_is_malformed(self):
        for status in (7, False, [], {}):
            with self.subTest(status=status):
                self.list_conflicts(["/README.md"])
                type(self).requests = []
                self.entries[0]["resolutionStatus"] = status
                result = self.invoke("list", "repo", "7", error=True)
                self.assertIn("resolutionStatus", result.stderr)
                self.assertEqual(len(self.requests), 1)

    def test_apply_counts_null_and_missing_status_before_polling(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.list_conflicts(["/README.md", "/notes.txt"])
                type(self).requests = []
                if missing:
                    self.entries[1].pop("resolutionStatus")
                else:
                    self.entries[1]["resolutionStatus"] = None
                result = self.invoke("apply", "repo", "7", "1", str(resolution))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "resolution: resolved None\n1 conflicts remaining\n")
                self.assertEqual(len(self.requests), 3)

    def test_usage_errors_do_not_return_conflict_codes(self):
        for arguments in ((), ("unknown",), ("list", "repo"), ("list", "repo", "7", "extra"),
                          ("apply", "repo", "7", "1"), ("apply", "repo", "7", "1", "file", "extra")):
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments, error=True)
                self.assertIn("expected list", result.stderr)
                self.assertEqual(self.requests, [])
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        result = self.invoke("apply", "repo", "7", "not-a-number", str(resolution), error=True)
        self.assertIn("ValueError", result.stderr)
        self.assertEqual(self.requests, [])

    def test_rest_errors_at_every_list_and_apply_request(self):
        self.list_conflicts(["/README.md"])
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for command in (("list", "repo", "7"), ("apply", "repo", "7", "1", str(resolution))):
            for request_number in range(1, 5):
                for status in (401, 500):
                    with self.subTest(command=command[0], request=request_number, status=status):
                        type(self).requests = []
                        type(self).override_request = request_number
                        type(self).override_status = status
                        result = self.invoke(*command, error=True)
                        self.assertIn(f"HTTP Error {status}", result.stderr)
                        self.assertEqual(len(self.requests), request_number)
                        self.assertNotIn("verdict:", result.stdout)
                        self.assertNotIn("conflicts remaining", result.stdout)
                        self.assertNotIn("mergeStatus:", result.stdout)
                        if command[0] == "apply" and request_number > 2:
                            self.assertEqual(self.entries[0]["resolutionStatus"], "resolved")

    def test_malformed_responses_are_operational_errors(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for command, request_number, body in (
            (("list", "repo", "7"), 1, b"not-json"),
            (("list", "repo", "7"), 1, b"[]"),
            (("list", "repo", "7"), 1, b"null"),
            (("list", "repo", "7"), 1, b"{}"),
            (("list", "repo", "7"), 1, b'{"value": null}'),
            (("list", "repo", "7"), 1, b'{"value": {}}'),
            (("list", "repo", "7"), 1, b'{"value": [null]}'),
            (("list", "repo", "7"), 1, b'{"value": [{}]}'),
            (("apply", "repo", "7", "1", str(resolution)), 1, b"not-json"),
            (("apply", "repo", "7", "1", str(resolution)), 1, b'{"lastMergeCommit": "invalid"}'),
            (("apply", "repo", "7", "1", str(resolution)), 1, b'{"lastMergeCommit": {"commitId": 7}}'),
            (("apply", "repo", "7", "1", str(resolution)), 2, b"{}"),
            (("apply", "repo", "7", "1", str(resolution)), 2, b'{"resolutionStatus": null}'),
            (("apply", "repo", "7", "1", str(resolution)), 3, b'{"value": [null]}'),
            (("apply", "repo", "7", "1", str(resolution)), 4, b"not-json"),
            (("apply", "repo", "7", "1", str(resolution)), 4, b'{"mergeStatus": []}'),
            (("apply", "repo", "7", "1", str(resolution)), 4, b'{"lastMergeCommit": {"commitId": []}}'),
        ):
            with self.subTest(command=command[0], request=request_number, body=body):
                type(self).requests = []
                type(self).override_request = request_number
                type(self).override_body = body
                self.invoke(*command, error=True)
                self.assertEqual(len(self.requests), request_number)

    def test_token_command_failures_are_operational_errors(self):
        self.environment.pop("ADO_TOKEN")
        self.environment["AZ_EXIT"] = "7"
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for command in (("list", "repo", "7"), ("apply", "repo", "7", "1", str(resolution))):
            with self.subTest(command=command[0]):
                result = self.invoke(*command, error=True)
                self.assertIn("CalledProcessError", result.stderr)
                self.assertEqual(self.requests, [])
        self.environment.pop("AZ_EXIT")
        self.environment["AZ_TOKEN"] = ""
        result = self.invoke("list", "repo", "7", error=True)
        self.assertIn("empty access token", result.stderr)
        self.assertEqual(self.requests, [])

    def test_token_failure_keeps_first_nonempty_diagnostic_without_stdout(self):
        self.environment.pop("ADO_TOKEN")
        self.environment.update({"AZ_EXIT": "7", "AZ_TOKEN": "private-token-output",
                                 "AZ_ERROR": "\n  \nPlease run az login\ncredential details omitted"})
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for command in (("list", "repo", "7"), ("apply", "repo", "7", "1", str(resolution))):
            with self.subTest(command=command[0]):
                result = self.invoke(*command, error=True)
                self.assertTrue(result.stderr.endswith(": Please run az login\n"), result.stderr)
                self.assertNotIn("private-token-output", result.stdout + result.stderr)
                self.assertNotIn("credential details omitted", result.stdout + result.stderr)
                self.assertEqual(self.requests, [])

    def test_merge_failure_keeps_first_nonempty_diagnostic_and_redacts_tokens(self):
        self.list_conflicts(["/README.md"])
        stub_directory = self.root / "merge-error-bin"
        stub_directory.mkdir()
        git = stub_directory / "git"
        git.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$GIT_ARGS"\n'
                       'printf "%s\\n" "$GIT_ERROR" >&2\nexit 255\n')
        git.chmod(0o700)
        self.environment.update({"PATH": str(stub_directory) + os.pathsep + self.environment["PATH"],
                                 "GIT_ARGS": str(self.root / "git-arguments")})
        for detail, expected in (("", ""), ("\n \n", ""),
                                 ("\n  \nfatal: cannot merge binary files\ncredential details omitted",
                                  ": fatal: cannot merge binary files"),
                                 ("\nfatal: stub-token Bearer private-bearer-value\ncredential details omitted",
                                  ": fatal: [REDACTED] Bearer [REDACTED]")):
            with self.subTest(detail=detail):
                type(self).requests = []
                self.environment["GIT_ERROR"] = detail
                result = self.invoke("list", "repo", "7", error=True)
                self.assertTrue(result.stderr.endswith(f"{expected}\n"), result.stderr)
                self.assertIn("CalledProcessError", result.stderr)
                self.assertNotIn("credential details omitted", result.stdout + result.stderr)
                self.assertNotIn("stub-token", result.stdout + result.stderr)
                self.assertNotIn("private-bearer-value", result.stdout + result.stderr)
                self.assertNotIn("verdict:", result.stdout)
                self.assertEqual(len(self.requests), 4)
                self.assertTrue((self.root / "git-arguments").read_text().startswith("merge-file -p "))

    def test_file_and_merge_subprocess_failures_are_operational_errors(self):
        for path in (self.root / "missing-resolution.md", self.root):
            with self.subTest(path=path):
                self.invoke("apply", "repo", "7", "1", str(path), error=True)
                self.assertEqual(self.requests, [])
        self.list_conflicts(["/README.md"])
        type(self).requests = []
        type(self).blobs = dict.fromkeys(("base", "source", "target"), b"\0binary\n")
        result = self.invoke("list", "repo", "7", error=True)
        self.assertIn("CalledProcessError", result.stderr)
        self.assertNotIn("verdict:", result.stdout)
        self.assertEqual(len(self.requests), 4)

    def test_document_extensions_and_three_way_output(self):
        for path in ("/README.MD", "/guide.markdown", "/guide.rst", "/notes.txt", "/guide.adoc",
                     "/readme.txt", "/index.txt", "/changelog.txt", "/verify.txt", "/build-status.txt",
                     "NOTES.TXT", "/docs/README.TXT", "/docs/BUILD-STATUS.TXT"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.splitlines()[0],
                                 f"conflict 1 editEdit {path} status=unresolved class=doc")
                self.assertTrue(result.stdout.endswith(
                    "verdict: doc-only candidate, eligible for forge-side resolution (tier 1) after verifying no code or tooling reads these files\n"))
                files = re.search(r"^  files: (\S+)/base \1/source \1/target  three-way \(with markers\): \1/three-way$",
                                  result.stdout, re.MULTILINE)
                self.assertIsNotNone(files)
                directory = Path(files.group(1))
                for side, content in self.blobs.items():
                    self.assertEqual((directory / side).read_bytes(), content)
                self.assertIn("<<<<<<< PR branch", (directory / "three-way").read_text())
                self.assertIn("  hunk at line 1\n", result.stdout)
                self.assertIn("    source fact\n", result.stdout)
                self.assertIn("    target fact\n", result.stdout)
                self.assertEqual(self.requests[0][2],
                                 {"api-version": ["7.1-preview.1"], "includeObsolete": ["false"]})
                self.assertEqual(len(self.requests), 4)
                for request in self.requests[1:]:
                    self.assertEqual(request[2], {"api-version": ["7.1"], "$format": ["octetStream"]})

    def test_mechanical_candidates_keep_review(self):
        for path in ("/App.csproj", "/Directory.Packages.props", "/Directory.Build.props",
                     "/global.json", "/.editorconfig", "/settings.properties", "/settings.ini",
                     "/settings.env", "/.env", "/.npmrc", "/.yarnrc",
                     "Directory.Build.props", "src/Directory.Packages.props", "/src/GLOBAL.JSON",
                     "/src/APP.CSPROJ", "/config/.EDITORCONFIG", "/config/SETTINGS.INI",
                     "/requirements.txt", "/constraints.txt", "/deps/requirements-dev.txt",
                     "/deps/constraints-test.txt", "REQUIREMENTS.TXT", "/deps/CONSTRAINTS-TEST.TXT"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"conflict 1 editEdit {path} status=unresolved class=mechanical\n", result.stdout)
                self.assertIn("  hunk at line 1\n", result.stdout)
                self.assertIn("skip-test,document rerun (tier 4) if the hunks hold no code", result.stdout)
                self.assertNotIn("skip-review", result.stdout)

    def test_literal_conflict_markers_cannot_crash_hunk_scanning(self):
        for path in ("/README.md", "/settings.ini"):
            for content, hunk_count in ((b"example\n<<<<<<< unmatched\nlast line\n", 1),
                                        (b"<<<<<<< at EOF", 1),
                                        (b"<<<<<<< matched\n=======\n>>>>>>> end\n<<<<<<< unmatched\n", 2),
                                        (b">>>>>>> orphan\n", 0)):
                with self.subTest(path=path, content=content):
                    type(self).blobs = dict.fromkeys(("base", "source", "target"), content)
                    result = self.list_conflicts([path])
                    self.assertEqual(result.returncode, 0 if path.endswith(".md") else 1)
                    self.assertEqual(result.stdout.count("  hunk at line"), hunk_count)
                    self.assertIn("verdict:", result.stdout)

    def test_lock_candidates_never_fetch_mergeable_blobs(self):
        for path in ("/packages.lock.json", "/yarn.lock", "packages.lock.json",
                     "/src/PACKAGES.LOCK.JSON", "/src/YARN.LOCK"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 1)
                self.assertIn("class=mechanical\n", result.stdout)
                self.assertNotIn("  files:", result.stdout)
                self.assertEqual(len(self.requests), 1)

    def test_code_and_non_edit_conflicts_are_not_fasttracked(self):
        for path in ("/App.cs", "/App.ts", "/infra.tf", "/azure-pipelines.yml", "/ci.yaml",
                     "/Dockerfile", "/README.md.cs", "/settings.json", "/build.targets",
                     "/custom.props", "/test.runsettings", "/appglobal.json",
                     "/apppackages.lock.json", "/app.editorconfig", "/app.npmrc",
                     "/app.yarnrc", "/Custom.Directory.Build.props", "/Directory.Other.props",
                     "appglobal.json", "/src/CUSTOM.PROPS", "/src/BUILD.TARGETS",
                     "/src/TEST.RUNSETTINGS", "/src/APPGLOBAL.JSON",
                     "/src/APPPACKAGES.LOCK.JSON", "/src/APP.EDITORCONFIG",
                     "/CMakeLists.txt", "/docs/guide.txt", "/deps/myrequirements.txt",
                     "/docs/not-readme.txt", "CMAKELISTS.TXT", "/src/CONFIG.TXT"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 2)
                self.assertIn("class=CODE\n", result.stdout)
                self.assertIn("ordinary branch-sync procedure and full validation", result.stdout)
                self.assertEqual(len(self.requests), 1)
        for conflict_type in ("editDelete", "renameRename"):
            for path in ("/README.md", "/Directory.Build.props", "/App.csproj", "/settings.ini",
                         "/packages.lock.json", "/notes.txt", "/requirements.txt"):
                with self.subTest(conflict_type=conflict_type, path=path):
                    result = self.list_conflicts([path], conflict_type)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn(f"conflict 1 {conflict_type} {path} status=unresolved class=CODE\n", result.stdout)
                    self.assertEqual(len(self.requests), 1)

    def test_mixed_conflicts_and_empty_response(self):
        result = self.list_conflicts(["/README.md", "/packages.lock.json"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("class=doc\n", result.stdout)
        self.assertIn("class=mechanical\n", result.stdout)
        result = self.list_conflicts(["/README.md", "/App.cs"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("class=CODE\n", result.stdout)
        for paths in (("/Directory.Build.props", "/custom.props"),
                      ("/custom.props", "/Directory.Build.props"),
                      ("/packages.lock.json", "/apppackages.lock.json"),
                      ("/README.md", "/build.targets"), ("/notes.txt", "/CMakeLists.txt"),
                      ("/CMakeLists.txt", "/notes.txt"), ("/requirements.txt", "/guide.txt")):
            with self.subTest(paths=paths):
                result = self.list_conflicts(paths)
                self.assertEqual(result.returncode, 2)
                self.assertIn("class=CODE\n", result.stdout)
                self.assertTrue(result.stdout.endswith(
                    "verdict: CODE conflict, use the ordinary branch-sync procedure and full validation\n"))
        for paths in (("/notes.txt", "/requirements.txt"), ("/constraints.txt", "/notes.txt")):
            with self.subTest(paths=paths):
                result = self.list_conflicts(paths)
                self.assertEqual(result.returncode, 1)
                self.assertIn("class=doc\n", result.stdout)
                self.assertIn("class=mechanical\n", result.stdout)
        result = self.list_conflicts([])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "no conflicts\n")

    def test_token_is_fetched_with_azure_cli_when_not_supplied(self):
        self.environment.pop("ADO_TOKEN")
        result = self.list_conflicts([])
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / "az-arguments").read_text().splitlines(),
                         ["account", "get-access-token", "--resource",
                          "499b84ac-1321-427f-aa17-267ca6975798", "--query", "accessToken", "--output", "tsv"])

    def test_apply_sends_file_bytes_and_reports_merge_result(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes("merged facts é\n".encode())
        result = self.invoke("apply", "repo", "7", "1", str(resolution))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "resolution: resolved None\nmergeStatus: succeeded lastMergeCommit: 01234567\n")
        self.assertEqual(len(self.requests), 4)
        self.assertEqual([request[0] for request in self.requests], ["GET", "PATCH", "GET", "GET"])
        self.assertEqual(self.requests[1][2], {"api-version": ["7.1-preview.1"]})
        self.assertEqual(self.requests[1][4],
                         {"conflictId": 1, "conflictType": "editEdit", "resolutionStatus": "resolved",
                          "resolution": {"mergeType": "userMerged", "userMergedContent": list(resolution.read_bytes())}})
        self.assertEqual(self.requests[0][2], {"api-version": ["7.1"]})
        self.assertEqual(self.requests[2][2], {"api-version": ["7.1-preview.1"], "includeObsolete": ["false"]})
        self.assertEqual(self.requests[3][2], {"api-version": ["7.1"]})

    def test_apply_accepts_no_error_resolution_encodings(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for response in ({"resolutionStatus": "resolved"},
                         {"resolutionStatus": "resolved", "resolutionError": "none"},
                         {"resolutionStatus": "resolved", "resolutionError": 0}):
            with self.subTest(response=response):
                type(self).requests = []
                type(self).resolution = response
                result = self.invoke("apply", "repo", "7", "1", str(resolution))
                self.assertEqual(result.returncode, 0)
                self.assertIn("mergeStatus: succeeded", result.stdout)
                self.assertEqual(len(self.requests), 4)

    def test_apply_multiple_conflicts_reports_remaining_before_polling(self):
        self.list_conflicts(["/README.md", "/notes.txt", "/guide.md"])
        type(self).requests = []
        type(self).entries[2]["resolutionStatus"] = "resolved"
        type(self).pull_requests = [{"mergeStatus": "conflicts", "lastMergeCommit": {"commitId": "old"}}]
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        result = self.invoke("apply", "repo", "7", "1", str(resolution))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "resolution: resolved None\n1 conflicts remaining\n")
        self.assertEqual(len(self.requests), 3)
        self.assertTrue(self.requests[-1][1].endswith("/conflicts"))
        self.assertEqual([entry["resolutionStatus"] for entry in self.entries], ["resolved", "unresolved", "resolved"])
        type(self).requests = []
        type(self).pull_requests = [
            {"mergeStatus": "conflicts", "lastMergeCommit": {"commitId": "old"}},
            {"mergeStatus": "succeeded", "lastMergeCommit": {"commitId": "new"}},
        ]
        result = self.invoke("apply", "repo", "7", "2", str(resolution))
        self.assertEqual(result.returncode, 0)
        self.assertIn("mergeStatus: succeeded", result.stdout)
        self.assertNotIn("conflicts remaining", result.stdout)
        self.assertEqual(len(self.requests), 4)

    def test_apply_tolerates_stale_and_pending_merge_status(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for previous_commit in (None, {"commitId": "old"}):
            with self.subTest(previous_commit=previous_commit):
                type(self).requests = []
                type(self).pull_requests = [
                    {"mergeStatus": "conflicts", "lastMergeCommit": previous_commit},
                    {"mergeStatus": "conflicts", "lastMergeCommit": previous_commit},
                    {"mergeStatus": "conflicts"},
                    {"mergeStatus": "queued", "lastMergeCommit": previous_commit},
                    {"mergeStatus": "notSet", "lastMergeCommit": previous_commit},
                    {"lastMergeCommit": previous_commit},
                    {"mergeStatus": "succeeded", "lastMergeCommit": {"commitId": "new"}},
                ]
                result = self.invoke("apply", "repo", "7", "1", str(resolution), fast_poll=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "resolution: resolved None\nmergeStatus: succeeded lastMergeCommit: new\n")
                self.assertEqual(len(self.requests), 9)

    def test_apply_reports_changed_conflicts_or_terminal_failure(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for merge_status in ("conflicts", "failure", "rejectedByPolicy"):
            with self.subTest(merge_status=merge_status):
                type(self).requests = []
                type(self).pull_requests = [
                    {"mergeStatus": "conflicts", "lastMergeCommit": {"commitId": "old"}},
                    {"mergeStatus": merge_status, "lastMergeCommit": {"commitId": "new"}},
                ]
                result = self.invoke("apply", "repo", "7", "1", str(resolution))
                self.assertEqual(result.returncode, 3)
                self.assertIn(f"mergeStatus: {merge_status}", result.stdout)
                self.assertEqual(len(self.requests), 4)

    def test_apply_failed_patch_does_not_poll_merge(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for response in ({"resolutionStatus": "unresolved", "resolutionError": None},
                         {"resolutionStatus": "resolved", "resolutionError": "invalid resolution"}):
            with self.subTest(response=response):
                type(self).requests = []
                type(self).resolution = response
                result = self.invoke("apply", "repo", "7", "1", str(resolution))
                self.assertEqual(result.returncode, 3)
                self.assertEqual(len(self.requests), 2)
                self.assertNotIn("mergeStatus:", result.stdout)

    def test_apply_polling_is_bounded_for_stale_or_pending_results(self):
        resolution = self.root / "resolution.md"
        resolution.write_bytes(b"merged facts\n")
        for merge_status in ("conflicts", "queued", "notSet", None):
            with self.subTest(merge_status=merge_status):
                type(self).requests = []
                type(self).pull_requests = [{"mergeStatus": merge_status, "lastMergeCommit": {"commitId": "old"}}]
                result = self.invoke("apply", "repo", "7", "1", str(resolution), fast_poll=True)
                self.assertEqual(result.returncode, 4)
                self.assertEqual(result.stdout, "resolution: resolved None\nmergeStatus still pending\n")
                self.assertEqual(len(self.requests), 33)


unittest.main(verbosity=2)
PY

pass "md-conflict-fastpath CLI classifies paths and exercises REST with an isolated stub"
