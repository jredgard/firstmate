# Disposable stateful Azure DevOps PR-conflicts stand-in; conflict blobs come from a real git repo.
import json, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
REPO = sys.argv[1]; SCEN = json.load(open(sys.argv[2])); PORT = int(sys.argv[3])
LOG = open(sys.argv[4], "a")
state = {}
for pr, s in SCEN.items():
    state[pr] = {"entries": s["conflicts"], "merge": "conflicts", "commit": "aaaaaaaa1111", "stale_gets": s.get("stale_gets", 0), "patches": []}
def blob(oid):
    return subprocess.check_output(["git", "-C", REPO, "cat-file", "blob", oid])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json"):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        p = urlsplit(self.path).path.split("/")
        LOG.write(f"GET {self.path} auth={'Bearer' if self.headers.get('Authorization','').startswith('Bearer ') else 'none'}\n"); LOG.flush()
        if self.headers.get("Authorization") != "Bearer live-lab-token":
            return self.send(401, b'{"message":"TF400813: unauthorized"}')
        if "blobs" in p:
            return self.send(200, blob(p[-1]), "application/octet-stream")
        pr = p[p.index("pullRequests") + 1]; st = state[pr]
        if p[-1] == "conflicts":
            return self.send(200, json.dumps({"count": len(st["entries"]), "value": st["entries"]}).encode())
        if st["stale_gets"] > 0 and all(e["resolutionStatus"] == "resolved" for e in st["entries"]):
            st["stale_gets"] -= 1
            return self.send(200, json.dumps({"mergeStatus": "conflicts", "lastMergeCommit": {"commitId": "aaaaaaaa1111"}}).encode())
        return self.send(200, json.dumps({"mergeStatus": st["merge"], "lastMergeCommit": {"commitId": st["commit"]}}).encode())
    def do_PATCH(self):
        p = urlsplit(self.path).path.split("/"); pr = p[p.index("pullRequests") + 1]; cid = int(p[-1]); st = state[pr]
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        content = bytes(body["resolution"]["userMergedContent"])
        LOG.write(f"PATCH {self.path} mergeType={body['resolution']['mergeType']} status={body['resolutionStatus']} bytes={len(content)}\n"); LOG.flush()
        st["patches"].append(content.decode())
        open(f"{sys.argv[5]}/pr{pr}-c{cid}-merged.txt", "wb").write(content)
        for e in st["entries"]:
            if e["conflictId"] == cid: e["resolutionStatus"] = "resolved"
        if all(e["resolutionStatus"] == "resolved" for e in st["entries"]):
            st["merge"] = "succeeded"; st["commit"] = "bbbbbbbb2222"
        self.send(200, json.dumps({"conflictId": cid, "resolutionStatus": "resolved", "resolutionError": "none"}).encode())
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
