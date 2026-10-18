# Records every POST body NOTIFY_URL receives, one per line (stands in for ntfy or similar).
import http.server, sys
OUT = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        open(OUT, "a").write(body.replace("\n", " ") + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
