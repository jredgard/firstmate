#!/usr/bin/env python3
"""Loopback stand-in for a LiteLLM gateway: logs every request (path + which
credential arrived, masked) per listening port and answers Anthropic
/v1/messages with a tiny valid (streaming or non-streaming) reply."""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1]
PORTS = {int(p.split('=')[0]): p.split('=')[1] for p in sys.argv[2:]}
lock = threading.Lock()

def mask(v):
    return None if v is None else (v[:14] + '...' if len(v) > 14 else v)

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def _rec(self, body):
        port = self.server.server_address[1]
        auth = self.headers.get('authorization')
        rec = {'t': time.strftime('%H:%M:%S'), 'gateway': PORTS.get(port), 'port': port,
               'method': self.command, 'path': self.path,
               'x-api-key': self.headers.get('x-api-key'),
               'authorization': auth}
        try:
            j = json.loads(body or b'{}'); rec['model'] = j.get('model'); rec['stream'] = j.get('stream')
        except Exception: j = {}
        with lock, open(LOG, 'a') as f: f.write(json.dumps(rec) + '\n')
        return j
    def _send(self, code, obj, ctype='application/json'):
        data = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code); self.send_header('content-type', ctype)
        self.send_header('content-length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self._rec(b''); self._send(200, {'data': [], 'has_more': False})
    def do_HEAD(self):
        self._rec(b''); self.send_response(200); self.send_header('content-length','0'); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0); body = self.rfile.read(n)
        j = self._rec(body)
        port = self.server.server_address[1]
        if 'count_tokens' in self.path:
            return self._send(200, {'input_tokens': 10})
        if not self.path.startswith('/v1/messages'):
            return self._send(200, {})
        text = f'GATEWAY-{PORTS.get(port, port)}-OK'
        model = j.get('model', 'fake')
        msg = {'id': 'msg_fake', 'type': 'message', 'role': 'assistant', 'model': model,
               'content': [], 'stop_reason': None, 'stop_sequence': None,
               'usage': {'input_tokens': 10, 'output_tokens': 1}}
        if j.get('stream'):
            ev = []
            def e(t, d): ev.append(f'event: {t}\ndata: {json.dumps(d)}\n\n')
            e('message_start', {'type': 'message_start', 'message': msg})
            e('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            e('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}})
            e('content_block_stop', {'type': 'content_block_stop', 'index': 0})
            e('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 5}})
            e('message_stop', {'type': 'message_stop'})
            return self._send(200, ''.join(ev).encode(), 'text/event-stream')
        msg['content'] = [{'type': 'text', 'text': text}]; msg['stop_reason'] = 'end_turn'
        return self._send(200, msg)

for port in PORTS:
    s = ThreadingHTTPServer(('127.0.0.1', port), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
print('listening', PORTS, flush=True)
while True: time.sleep(3600)
