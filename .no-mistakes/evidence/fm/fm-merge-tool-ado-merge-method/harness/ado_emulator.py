#!/usr/bin/env python3
"""Disposable local Azure DevOps REST emulator for one PR (validation fixture).

Serves HTTPS for dev.azure.com on 127.0.0.1:<port>. Backed by a real bare git
repository: completing the PR performs the requested merge strategy on the
target branch exactly as Azure DevOps does (squash = one-parent commit,
noFastForward = two-parent merge commit with the source head as 2nd parent).
A blocking "Require a merge strategy" policy (type id fa4e907d-...-d171ab)
makes completion with a disallowed strategy fail 403, as the real server does.
Usage: ado_emulator.py <port> <certfile> <keyfile> <state-dir>
state-dir/config.json: {"repo": <bare repo>, "target": "main", "source": "fm/example",
  "strategy_policies": [ {settings...}, ... ], "token": "..."}
Every request is appended to state-dir/requests.log.
"""
import json, os, re, ssl, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, CERT, KEY, STATE = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
CFG = json.load(open(os.path.join(STATE, "config.json")))
PROJECT_ID = "11111111-1111-1111-1111-111111111111"
REVIEWER = "22222222-2222-2222-2222-222222222222"
STRATEGY_TYPE = "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"
MINREV_TYPE = "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"
PR_ID = 42
st = {"status": "active", "voted": False, "lastMergeCommit": None, "completionOptions": None}


def git(*args):
    return subprocess.run(["git", "-C", CFG["repo"], *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def source_head():
    # A completed PR keeps the source commit it completed at, even after the
    # source branch is deleted on the forge.
    if st.get("completedSource"):
        return st["completedSource"]
    return git("rev-parse", "refs/heads/" + CFG["source"])


def allowed(strategy):
    for s in CFG.get("strategy_policies", []):
        if "useSquashMerge" in s and not any(k in s for k in ("allowSquash", "allowNoFastForward", "allowRebase", "allowRebaseMerge")):
            ok = {"squash": s["useSquashMerge"], "noFastForward": not s["useSquashMerge"]}.get(strategy, False)
        else:
            key = {"squash": "allowSquash", "noFastForward": "allowNoFastForward",
                   "rebase": "allowRebase", "rebaseMerge": "allowRebaseMerge"}.get(strategy)
            ok = bool(key and s.get(key))
        if not ok:
            return False
    return True


def evaluations():
    vals = [{"status": "approved", "configuration": {"isBlocking": True, "isEnabled": True,
             "type": {"id": "0609b952-1397-4640-95ec-e00a01b2c241", "displayName": "Build"}}},
            {"status": "approved" if st["voted"] else "queued",
             "configuration": {"isBlocking": True, "isEnabled": True,
             "type": {"id": MINREV_TYPE, "displayName": "Minimum number of reviewers"},
             "settings": {"minimumApproverCount": 1}}}]
    for s in CFG.get("strategy_policies", []):
        vals.append({"status": "approved" if st["status"] == "completed" else "rejected",
                     "configuration": {"isBlocking": True, "isEnabled": True,
                     "type": {"id": STRATEGY_TYPE, "displayName": "Require a merge strategy"},
                     "settings": dict(s, scope=[{"refName": "refs/heads/" + CFG["target"], "matchKind": "Exact"}])}})
    return {"count": len(vals), "value": vals}


def pr_json():
    d = {"pullRequestId": PR_ID, "status": st["status"], "mergeStatus": "succeeded", "isDraft": False,
         "sourceRefName": "refs/heads/" + CFG["source"], "targetRefName": "refs/heads/" + CFG["target"],
         "lastMergeSourceCommit": {"commitId": source_head()},
         "repository": {"name": "Backend", "project": {"id": PROJECT_ID, "name": "Project One"}}}
    if st["lastMergeCommit"]:
        d["lastMergeCommit"] = {"commitId": st["lastMergeCommit"]}
        d["completionOptions"] = st["completionOptions"]
    return d


def complete(strategy):
    target = git("rev-parse", "refs/heads/" + CFG["target"])
    head = source_head()
    tree = git("merge-tree", "--write-tree", target, head).splitlines()[0]
    msg = "Merged PR %d: example change" % PR_ID
    if strategy == "squash":
        new = git("commit-tree", tree, "-p", target, "-m", msg)
    elif strategy == "noFastForward":
        new = git("commit-tree", tree, "-p", target, "-p", head, "-m", msg)
    else:
        raise ValueError(strategy)
    git("update-ref", "refs/heads/" + CFG["target"], new, target)
    return new


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with open(os.path.join(STATE, "requests.log"), "a") as f:
            f.write("%s %s %s\n" % (method, self.path, body))
        if self.headers.get("Authorization") != "Bearer " + CFG["token"]:
            return self.send(401, {"message": "TF400813: unauthorized"})
        p = self.path
        pr_path = "/acme/Project%20One/_apis/git/repositories/Backend/pullRequests/42"
        if method == "GET" and p == pr_path + "?api-version=7.1":
            return self.send(200, pr_json())
        if method == "GET" and p.startswith("/acme/%s/_apis/policy/evaluations?" % PROJECT_ID):
            return self.send(200, evaluations())
        if method == "PUT" and p == pr_path + "/reviewers/%s?api-version=7.1" % REVIEWER:
            if json.loads(body or "{}").get("vote") != 10:
                return self.send(400, {"message": "bad vote"})
            st["voted"] = True
            return self.send(200, {"id": REVIEWER, "vote": 10})
        if method == "PATCH" and p == pr_path + "?api-version=7.1":
            req = json.loads(body)
            opts = req.get("completionOptions") or {}
            strategy = opts.get("mergeStrategy", "noFastForward")
            if req.get("lastMergeSourceCommit", {}).get("commitId") != source_head():
                return self.send(409, {"message": "TF401192: source commit changed"})
            if not st["voted"]:
                return self.send(403, {"message": "TF401027: policy 'Minimum number of reviewers' not satisfied"})
            if not allowed(strategy):
                return self.send(403, {"typeKey": "PullRequestCompletionPolicyViolation", "message":
                    "TF401181: The pull request cannot be completed: merge strategy '%s' is not allowed by policy 'Require a merge strategy' on refs/heads/%s." % (strategy, CFG["target"])})
            st["completedSource"] = source_head()
            st["lastMergeCommit"] = complete(strategy)
            st["completionOptions"] = opts
            st["status"] = "completed"
            with open(os.path.join(STATE, "completed.json"), "w") as f:
                json.dump({"strategy": strategy, "mergeCommit": st["lastMergeCommit"], "sourceHead": source_head()}, f)
            return self.send(200, pr_json())
        return self.send(404, {"message": "not found: %s %s" % (method, p)})

    def do_GET(self): self.handle_any("GET")
    def do_PUT(self): self.handle_any("PUT")
    def do_PATCH(self): self.handle_any("PATCH")
    def do_POST(self): self.handle_any("POST")


srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(os.path.join(STATE, "ready"), "w").close()
srv.serve_forever()
