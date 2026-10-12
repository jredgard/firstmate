import http.server, ssl, sys, os, json, re, datetime
state_dir, log, port, cert, key = sys.argv[1:6]
pat = re.compile(r'^/acme/Project%20One/_apis/git/repositories/Backend/pullRequests/(\d+)\?api-version=7\.1$')
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        m = pat.match(self.path)
        auth = self.headers.get('Authorization')
        with open(log, 'a') as f:
            f.write(f"{datetime.datetime.now().isoformat()} GET {self.path} auth_ok={auth=='Bearer lab-token'}\n")
        if auth != 'Bearer lab-token':
            self.send_response(401); self.end_headers(); return
        if not m or not os.path.exists(os.path.join(state_dir, m.group(1) + '.state')):
            self.send_response(404); self.end_headers(); return
        n = int(m.group(1))
        st = open(os.path.join(state_dir, m.group(1) + '.state')).read().strip()
        status, merge = {'active': ('active','succeeded'), 'conflicts': ('active','conflicts'),
                         'abandoned': ('abandoned','succeeded'), 'completed': ('completed','succeeded')}[st]
        body = json.dumps({"pullRequestId": n, "status": status, "mergeStatus": merge, "isDraft": False,
            "lastMergeSourceCommit": {"commitId": "a"*40},
            "repository": {"name": "Backend", "project": {"id": "11111111-1111-1111-1111-111111111111", "name": "Project One"}}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', int(port)), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
