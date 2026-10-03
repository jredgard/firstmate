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
        az.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$AZ_ARGS"\nprintf "stub-token\\n"\n')
        az.chmod(0o700)
        cls.entries = []
        cls.requests = []
        cls.blobs = {"base": b"before\n", "source": b"source fact\n", "target": b"target fact\n"}
        cls.merge_status = "succeeded"

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_arguments):
                pass

            def do_GET(self):
                route = urlsplit(self.path)
                query = parse_qs(route.query)
                cls.requests.append(("GET", route.path, query, self.headers.get("Authorization"), None))
                if route.path == "/fixture/_apis/git/repositories/repo/pullRequests/7/conflicts":
                    self.reply(json.dumps({"count": len(cls.entries), "value": cls.entries}).encode())
                elif route.path.startswith("/fixture/_apis/git/repositories/repo/blobs/"):
                    self.reply(cls.blobs[route.path.rsplit("/", 1)[1]])
                elif route.path == "/fixture/_apis/git/repositories/repo/pullRequests/7":
                    self.reply(json.dumps({"mergeStatus": cls.merge_status,
                                           "lastMergeCommit": {"commitId": "0123456789abcdef"}}).encode())
                else:
                    self.send_error(404)

            def do_PATCH(self):
                route = urlsplit(self.path)
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                cls.requests.append(("PATCH", route.path, parse_qs(route.query),
                                     self.headers.get("Authorization"), payload))
                if route.path == "/fixture/_apis/git/repositories/repo/pullRequests/7/conflicts/1":
                    self.reply(b'{"resolutionStatus": "resolved", "resolutionError": null}')
                else:
                    self.send_error(404)

            def reply(self, content):
                self.send_response(200)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

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
        type(self).requests = []
        type(self).entries = []
        type(self).merge_status = "succeeded"
        self.environment = os.environ.copy()
        self.environment.update({
            "ADO_ORG": f"http://127.0.0.1:{self.server.server_port}",
            "ADO_PROJECT": "fixture",
            "ADO_TOKEN": "stub-token",
            "PATH": str(self.fakebin) + os.pathsep + self.environment["PATH"],
            "AZ_ARGS": str(self.root / "az-arguments"),
            "TMPDIR": str(self.root),
        })

    def invoke(self, *arguments):
        result = subprocess.run([sys.executable, HELPER, *arguments], env=self.environment,
                                capture_output=True, text=True, timeout=10)
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

    def test_document_extensions_and_three_way_output(self):
        for path in ("/README.MD", "/guide.markdown", "/guide.rst", "/notes.txt", "/guide.adoc"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.splitlines()[0],
                                 f"conflict 1 editEdit {path} status=unresolved class=doc")
                self.assertTrue(result.stdout.endswith(
                    "verdict: doc-only, eligible for forge-side resolution (tier 1)\n"))
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
                     "/global.json", "/.editorconfig", "/test.runsettings"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"conflict 1 editEdit {path} status=unresolved class=mechanical\n", result.stdout)
                self.assertIn("  hunk at line 1\n", result.stdout)
                self.assertIn("skip-test,document rerun (tier 4) if the hunks hold no code", result.stdout)
                self.assertNotIn("skip-review", result.stdout)

    def test_lock_candidates_never_fetch_mergeable_blobs(self):
        for path in ("/packages.lock.json", "/yarn.lock"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 1)
                self.assertIn("class=mechanical\n", result.stdout)
                self.assertNotIn("  files:", result.stdout)
                self.assertEqual(len(self.requests), 1)

    def test_code_and_non_edit_conflicts_are_not_fasttracked(self):
        for path in ("/App.cs", "/App.ts", "/infra.tf", "/azure-pipelines.yml", "/ci.yaml",
                     "/Dockerfile", "/README.md.cs", "/settings.json"):
            with self.subTest(path=path):
                result = self.list_conflicts([path])
                self.assertEqual(result.returncode, 2)
                self.assertIn("class=CODE\n", result.stdout)
                self.assertIn("ordinary branch-sync procedure and full validation", result.stdout)
                self.assertEqual(len(self.requests), 1)
        for conflict_type in ("editDelete", "renameRename"):
            with self.subTest(conflict_type=conflict_type):
                result = self.list_conflicts(["/README.md"], conflict_type)
                self.assertEqual(result.returncode, 2)
                self.assertIn(f"conflict 1 {conflict_type} /README.md status=unresolved class=CODE\n", result.stdout)
                self.assertEqual(len(self.requests), 1)

    def test_mixed_conflicts_and_empty_response(self):
        result = self.list_conflicts(["/README.md", "/packages.lock.json"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("class=doc\n", result.stdout)
        self.assertIn("class=mechanical\n", result.stdout)
        result = self.list_conflicts(["/README.md", "/App.cs"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("class=CODE\n", result.stdout)
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
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.requests[0][0], "PATCH")
        self.assertEqual(self.requests[0][2], {"api-version": ["7.1-preview.1"]})
        self.assertEqual(self.requests[0][4],
                         {"conflictId": 1, "conflictType": "editEdit", "resolutionStatus": "resolved",
                          "resolution": {"mergeType": "userMerged", "userMergedContent": list(resolution.read_bytes())}})
        self.assertEqual(self.requests[1][2], {"api-version": ["7.1"]})
        type(self).merge_status = "conflicts"
        result = self.invoke("apply", "repo", "7", "1", str(resolution))
        self.assertEqual(result.returncode, 3)
        self.assertIn("mergeStatus: conflicts", result.stdout)


unittest.main(verbosity=2)
PY

pass "md-conflict-fastpath CLI classifies paths and exercises REST with an isolated stub"
