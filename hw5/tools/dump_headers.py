"""
Header discovery (Phase 1): a stdlib-only server that prints every request's
method, path, headers and body, and answers 200 so the client keeps going.
No GCP access needed.

Usage:  python3 tools/dump_headers.py [port]          (default 8080)
        ./http-client -d 127.0.0.1 -p 8080 -n 10 -r 528 -b none -w pages -i 11999
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def dump(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode(errors="replace") if length else ""
        print(json.dumps({"method": self.command, "path": self.path,
                          "headers": dict(self.headers), "body": body}), flush=True)
        reply = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(reply)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = dump

    def log_message(self, *args):  # keep stdout to one JSON line per request
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"Dumping headers on port {port}", file=sys.stderr)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
