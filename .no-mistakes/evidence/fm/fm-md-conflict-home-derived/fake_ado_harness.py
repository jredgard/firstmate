"""Disposable Azure DevOps stand-in: HTTPS CONNECT proxy terminating TLS for dev.azure.com.
Serves only the project prefix named in scenario.json (others 404 like real ADO) and logs requests."""
import json, re, ssl, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

LAB = Path(sys.argv[1])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(LAB / "srv.pem", LAB / "srv.key")

def scenario():
    return json.loads((LAB / "scenario.json").read_text())

def save(data):
    (LAB / "scenario.json").write_text(json.dumps(data))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_CONNECT(self):
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.connection = ctx.wrap_socket(self.connection, server_side=True)
        self.rfile = self.connection.makefile("rb")
        self.wfile = self.connection.makefile("wb", buffering=0)
        self.close_connection = False

    def log(self, method):
        with open(LAB / "requests.log", "a") as f:
            f.write(f"{method} https://{self.headers.get('Host')}{self.path} auth={'yes' if self.headers.get('Authorization','').startswith('Bearer ') else 'no'}\n")

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        s = scenario()
        path = urlsplit(self.path).path
        pre = s["prefix"] + "/_apis/git/repositories/" + s["repo"]
        if not path.startswith(pre + "/"):
            return s, None
        return s, path[len(pre):]

    def do_GET(self):
        self.log("GET")
        s, rest = self.route()
        if rest is None:
            return self.reply(404, b'{"message":"TF200016: The following project does not exist"}')
        if rest == f"/pullRequests/{s['pr']}/conflicts":
            return self.reply(200, json.dumps({"count": len(s["entries"]), "value": s["entries"]}).encode())
        if rest == f"/pullRequests/{s['pr']}":
            return self.reply(200, json.dumps({"mergeStatus": s.get("mergeStatus", "succeeded"),
                                               "lastMergeCommit": {"commitId": s.get("merge", "abcdef0123456789")}}).encode())
        m = re.fullmatch(r"/blobs/(\w+)", rest)
        if m:
            return self.reply(200, s["blobs"][m[1]].encode())
        self.reply(404, b"{}")

    def do_PATCH(self):
        self.log("PATCH")
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        s, rest = self.route()
        m = rest and re.fullmatch(rf"/pullRequests/{s['pr']}/conflicts/(\d+)", rest)
        if not m:
            return self.reply(404, b"{}")
        for e in s["entries"]:
            if e["conflictId"] == int(m[1]):
                e["resolutionStatus"] = "resolved"
        s["merge"] = "fedcba9876543210"
        s["patched_content"] = bytes(body["resolution"]["userMergedContent"]).decode()
        save(s)
        self.reply(200, json.dumps({"resolutionStatus": "resolved", "resolutionError": "none"}).encode())

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
(LAB / "port").write_text(str(srv.server_port))
srv.serve_forever()
