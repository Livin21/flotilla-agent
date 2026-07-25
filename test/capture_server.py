#!/usr/bin/env python3
"""Capture relay: records every request as JSON lines to the file in argv[2], listens on argv[1].
Sends X-Min-Agent on every response, mirroring flotilla-relay's index.js withHeaders(), so
heartbeat.sh's header-capture (Task 13 §8) has something real to capture in tests. Handles both
POST (send-event.sh/heartbeat.sh) and DELETE (revoke.sh's DELETE /v1/pairing, Task 13) so tests
can assert on the method/path/auth/body of any of them."""
import http.server, json, sys
out = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def _capture(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        out.write(json.dumps({"method": self.command, "path": self.path,
                              "auth": self.headers.get("Authorization", ""),
                              "body": body.decode()}) + "\n"); out.flush()
        self.send_response(202)
        self.send_header("X-Min-Agent", "1.0.0")
        self.end_headers(); self.wfile.write(b'{"ok":true}')
    def do_POST(self): self._capture()
    def do_DELETE(self): self._capture()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
