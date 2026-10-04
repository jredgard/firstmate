#!/usr/bin/env python3
"""Disposable forge emulator for live-driving bin/fm-pr-merge.sh.

An HTTP CONNECT proxy that terminates TLS for dev.azure.com / api.github.com
with a throwaway CA, then answers requests from a stateful model kept in
STATE (JSON file, re-read and re-written per request). Every request is
appended to LOG. Real curl, gh and gh-axi talk to it through https_proxy.
"""
import json, os, re, socket, ssl, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.path.dirname(os.path.abspath(__file__))
STATE = os.environ.get("EMU_STATE", os.path.join(DIR, "state.json"))
LOG = os.environ.get("EMU_LOG", os.path.join(DIR, "requests.log"))
LOCK = threading.Lock()
CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CTX.load_cert_chain(os.path.join(DIR, "pki/srv.pem"), os.path.join(DIR, "pki/srv.key"))

REVIEWER_TYPE = "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"
STRATEGY_TYPE = "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"


def load():
    with open(STATE) as f:
        return json.load(f)


def save(s):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=1)
    os.replace(tmp, STATE)


def log(line):
    with open(LOG, "a") as f:
        f.write(time.strftime("%H:%M:%S ") + line + "\n")


# ---------------------------------------------------------------- Azure DevOps
def ado_reviewer_status(a):
    approvals = sum(1 for v in a["votes"].values() if v >= 10)
    if approvals < a.get("minReviewers", 1):
        return "queued"  # what ADO reports until a qualifying vote exists
    # model ADO's asynchronous re-evaluation: a few reads still say queued
    if a.get("evalLagReads", 0) > 0:
        a["evalLagReads"] -= 1
        return "queued"
    return "approved"


def ado(h, method, path, query, body, s):
    a = s["ado"]
    if h.headers.get("Authorization") != "Bearer " + a["token"]:
        return 401, {"message": "TF400813: unauthorized"}
    pr = a["pr"]
    m = re.match(r"^/([^/]+)/([^/]+)/_apis/git/repositories/([^/]+)/pullRequests/(\d+)(/reviewers/([^/]+))?$", path)
    if m and int(m.group(4)) == pr["id"]:
        if m.group(5):
            if method != "PUT":
                return 405, {}
            if not a.get("reviewerCanVote", True):
                return 403, {"message": "TF401289: reviewer cannot vote"}
            a["votes"][m.group(6)] = json.loads(body)["vote"]
            return 200, {"id": m.group(6), "vote": a["votes"][m.group(6)]}
        if method == "GET":
            return 200, {"pullRequestId": pr["id"], "status": pr["status"], "mergeStatus": pr["mergeStatus"],
                         "isDraft": pr["isDraft"], "lastMergeSourceCommit": {"commitId": pr["head"]},
                         "repository": {"project": {"id": a["projectId"]}}}
        if method == "PATCH":
            req = json.loads(body)
            if ado_reviewer_status(dict(a, evalLagReads=0)) != "approved" or a["build"] != "approved":
                return 400, {"message": "TF401027: The pull request cannot be completed because policies are not met."}
            if req.get("lastMergeSourceCommit", {}).get("commitId") != pr["head"]:
                return 409, {"message": "TF401192: source commit changed"}
            pr["status"] = "completed"
            pr["completionOptions"] = req.get("completionOptions")
            return 200, {"pullRequestId": pr["id"], "status": "completed"}
    if re.match(r"^/[^/]+/[^/]+/_apis/policy/evaluations$", path) and method == "GET":
        art = query.get("artifactId", [""])[0]
        if not art.endswith("/%s/%d" % (a["projectId"], pr["id"])):
            return 404, {}
        return 200, {"value": [
            {"status": ado_reviewer_status(a), "configuration": {"isBlocking": True,
             "type": {"id": a.get("reviewerTypeIdCase", REVIEWER_TYPE), "displayName": a["reviewerName"]}}},
            {"status": a["build"], "configuration": {"isBlocking": True,
             "type": {"id": "0609b952-1397-4640-95ec-e00a01b2c241", "displayName": "Build"}}},
            {"status": "queued", "configuration": {"isBlocking": True,
             "type": {"id": STRATEGY_TYPE, "displayName": "Require a merge strategy"}}},
        ]}
    return 404, {"message": "no route"}


# ---------------------------------------------------------------------- GitHub
def gh_review_decision(g):
    if g["changesRequested"]:
        return "CHANGES_REQUESTED"
    if any(r["state"] == "APPROVED" and r["commit"] == g["head"] for r in g["reviews"]):
        return "APPROVED"
    return "REVIEW_REQUIRED" if g["requiredApprovals"] > 0 else None


def gh_mergeable(g):
    if g.get("unknownReads", 0) > 0:
        g["unknownReads"] -= 1
        return "UNKNOWN", "UNKNOWN"
    if gh_review_decision(g) in ("REVIEW_REQUIRED", "CHANGES_REQUESTED"):
        return "MERGEABLE", "BLOCKED"
    return "MERGEABLE", "CLEAN"


def gh_pr_node(g, fields):
    n = gh_pr_node_raw(g, fields)
    n["statusCheckRollup"] = n["commits"]
    return n


def gh_pr_node_raw(g, fields):
    mergeable, mss = gh_mergeable(g) if ("mergeable" in fields or "mergeStateStatus" in fields) else ("MERGEABLE", "CLEAN")
    return {
        "id": "PR_node9", "number": g["number"], "title": "lab PR", "url": "https://github.com/%s/pull/%d" % (g["repo"], g["number"]),
        "state": g["state"], "isDraft": False, "merged": g["state"] == "MERGED", "isInMergeQueue": False,
        "isMergeQueueEnabled": False, "mergeable": mergeable, "mergeStateStatus": mss,
        "headRefOid": g["head"], "headRefName": "feature", "baseRefName": "main",
        "headRepositoryOwner": {"id": "U_1", "login": g["repo"].split("/")[0]},
        "headRepository": {"id": "R_1", "name": g["repo"].split("/")[1]},
        "isCrossRepository": False, "maintainerCanModify": False,
        "reviewDecision": gh_review_decision(g), "author": {"__typename": "User", "login": g["author"], "id": "U_author", "name": "Captain Dev"},
        "baseRepository": {"nameWithOwner": g["repo"]},
        "autoMergeRequest": None, "mergeCommit": None,
        "commits": {"totalCount": 1, "nodes": [{"commit": {"oid": g["head"], "statusCheckRollup": {"contexts": {
            "pageInfo": {"hasNextPage": False, "endCursor": None},
            "nodes": [{"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS",
                       "startedAt": "2026-10-04T00:00:00Z", "completedAt": "2026-10-04T00:01:00Z",
                       "detailsUrl": "https://example.invalid", "workflowName": "ci", "checkSuite": {"workflowRun": None}}]}}}}]},
    }


def github(h, method, path, query, body, s):
    g = s["github"]
    auth = h.headers.get("Authorization", "")
    tok = auth.split()[-1] if auth else ""
    user = g["tokens"].get(tok)
    if user is None:
        return 401, {"message": "Bad credentials"}
    owner, name = g["repo"].split("/")
    if path == "/graphql" and method == "POST":
        req = json.loads(body)
        q = req.get("query", "")
        open(os.path.join(DIR, "queries.log"), "a").write(json.dumps(req) + "\n")
        v = req.get("variables", {})
        if "__type(" in q:
            names = {"PullRequest": ["id", "number", "title", "state", "isDraft", "merged", "mergeable", "mergeStateStatus",
                                     "headRefOid", "headRefName", "baseRefName", "reviewDecision", "isInMergeQueue",
                                     "isMergeQueueEnabled", "mergeQueueEntry", "autoMergeRequest", "author", "commits",
                                     "closingIssuesReferences", "projectItems", "headRepository", "headRepositoryOwner",
                                     "isCrossRepository", "maintainerCanModify", "url", "body", "labels"],
                     "WorkflowRun": ["event", "workflow", "databaseId", "url"],
                     "StatusCheckRollupContextConnection": ["checkRunCount", "checkRunCountsByState", "statusContextCount",
                                                            "statusContextCountsByState", "nodes", "pageInfo", "totalCount"]}
            data = {}
            for alias, tname in re.findall(r'(\w+):\s*__type\(name:\s*"(\w+)"\)', q):
                data[alias] = {"fields": [{"name": n} for n in names.get(tname, [])]}
            return 200, {"data": data}
        if "mergePullRequest" in q:
            inp = v.get("input", {})
            if user != g["merger"]:
                return 200, {"errors": [{"message": "merger mismatch"}]}
            if inp.get("expectedHeadOid") and inp["expectedHeadOid"] != g["head"]:
                return 200, {"errors": [{"message": "Head branch was modified"}]}
            if gh_review_decision(g) != "APPROVED" and g["requiredApprovals"] > 0:
                return 200, {"errors": [{"type": "UNPROCESSABLE", "message": "At least 1 approving review is required by reviewers with write access."}]}
            g["state"] = "MERGED"
            g["mergeMethod"] = inp.get("mergeMethod")
            return 200, {"data": {"mergePullRequest": {"clientMutationId": None}}}
        if "pullRequest(" in q or "pullRequest (" in q:
            return 200, {"data": {"repository": {"pullRequest": gh_pr_node(g, q), "id": "R_1",
                                                 "name": name, "owner": {"login": owner},
                                                 "viewerPermission": "WRITE", "mergeCommitAllowed": True,
                                                 "rebaseMergeAllowed": True, "squashMergeAllowed": True}}}
        if "repository(" in q:
            return 200, {"data": {"repository": {"id": "R_1", "name": name, "owner": {"login": owner},
                                                 "viewerPermission": "WRITE", "defaultBranchRef": {"name": "main"},
                                                 "mergeCommitAllowed": True, "rebaseMergeAllowed": True, "squashMergeAllowed": True,
                                                 "isPrivate": False}}}
        return 200, {"errors": [{"message": "emulator: unhandled query"}]}
    if path == "/user" and method == "GET":
        return 200, {"login": user, "id": 1, "type": "Bot" if user.endswith("[bot]") else "User"}
    if path == "/repos/%s/branches/main" % g["repo"]:
        return 200, {"name": "main", "protected": True, "protection": {"enabled": True,
                     "required_status_checks": {"enforcement_level": "non_admins", "contexts": [], "checks": []}}}
    if path == "/repos/%s/rules/branches/main" % g["repo"]:
        if g.get("rules403"):
            return 403, {"message": "Upgrade to GitHub Pro or make this repository public to enable this feature.",
                         "documentation_url": "https://docs.github.com/rest/repos/rules", "status": "403"}
        return 200, []
    if re.match(r"^/repos/%s/commits/[0-9a-f]{40}/check-runs$" % re.escape(g["repo"]), path):
        return 200, {"total_count": 1, "check_runs": [{"name": "build", "app": {"id": 15368}, "status": "completed", "conclusion": "success"}]}
    m = re.match(r"^/repos/%s/pulls/(\d+)/reviews$" % re.escape(g["repo"]), path)
    if m and method == "POST":
        req = json.loads(body)
        if user == g["author"]:
            return 422, {"message": "Unprocessable Entity", "errors": ["Can not approve your own pull request"]}
        if req.get("commit_id") and req["commit_id"] != g["head"]:
            return 422, {"message": "commit_id is not part of the pull request"}
        g["reviews"].append({"user": user, "state": "APPROVED" if req.get("event") == "APPROVE" else req.get("event"),
                             "commit": req.get("commit_id") or g["head"]})
        g["unknownReads"] = g.get("unknownAfterReview", 0)
        return 200, {"id": len(g["reviews"]), "user": {"login": user}, "state": "APPROVED", "commit_id": g["head"]}
    return 404, {"message": "Not Found", "documentation_url": "emulator"}


class Inner(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def handle_any(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks = []
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            body = b"".join(chunks).decode()
        else:
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode() if n else ""
        u = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(u.query)
        with LOCK:
            s = load()
            host = self.server_host
            if host == "dev.azure.com":
                code, obj = ado(self, self.command, u.path, query, body, s)
            elif host == "api.github.com":
                p = u.path[3:] if u.path.startswith("/v3") else u.path
                code, obj = github(self, self.command, p, query, body, s)
            else:
                code, obj = 404, {}
            save(s)
            short = body if len(body) < 300 else body[:300] + "..."
            if host == "api.github.com" and u.path == "/graphql":
                try:
                    qq = json.loads(body)["query"]
                    short = "graphql " + re.sub(r"\s+", " ", qq)[:160]
                except Exception:
                    pass
            log("%s %s %s %s -> %d %s" % (host, self.command, self.path, short.replace("\n", " "), code,
                                         json.dumps(obj)[:220]))
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_CONNECT(self):
        host = self.path.split(":")[0]
        if host not in ("dev.azure.com", "api.github.com", "github.com"):
            log("REFUSED CONNECT %s" % self.path)
            self.send_error(403)
            return
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.wfile.flush()
        try:
            tls = CTX.wrap_socket(self.connection, server_side=True)
        except Exception as e:
            log("TLS failure %s: %s" % (host, e))
            return
        handler = type("H", (Inner,), {"server_host": host})
        try:
            handler(tls, self.client_address, self.server)
        except Exception as e:
            log("inner error %s" % e)
        self.close_connection = True

    def do_GET(self):
        log("REFUSED plain %s" % self.path)
        self.send_error(403)


if __name__ == "__main__":
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Proxy).serve_forever()
