#!/usr/bin/env python3
"""Capture relay: records every request as JSON lines to the file in argv[2], listens on argv[1]."""
import http.server, json, sys
out = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        out.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization", ""),
                              "body": body.decode()}) + "\n"); out.flush()
        self.send_response(202); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
