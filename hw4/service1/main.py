"""
Service 1: web server running on a VM (started by startup/service1-startup.sh).

Serves files from the HW2 bucket:
  GET  /<file>          -> file is in the request path
  POST / (body = file)  -> file is in the payload (JSON {"file": ...},
                           form "file=...", or the raw filename)

Status codes / logging (structured logs in Cloud Logging):
  200 file found
  404 file missing                     -> severity WARNING
  501 PUT/DELETE/HEAD/CONNECT/...      -> severity ERROR
  400 request from a banned country    -> severity CRITICAL + Pub/Sub message
                                          to service 2

Auth: the VM's attached service account (no key files).
"""
import datetime
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

from google.cloud import storage, pubsub_v1
from google.cloud import logging as cloud_logging

BUCKET = os.environ.get("BUCKET", "cs528-amernor")
TOPIC = os.environ.get("TOPIC", "forbidden-requests")
PORT = int(os.environ.get("PORT", "8080"))

FORBIDDEN_COUNTRIES = {
    c.lower()
    for c in [
        "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
        "Libya", "Sudan", "Zimbabwe", "Syria",
    ]
}

storage_client = storage.Client()
bucket = storage_client.bucket(BUCKET)
PROJECT_ID = os.environ.get("PROJECT_ID", storage_client.project)
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC)

# Structured logging client (entries show up as jsonPayload in Cloud Logging)
log_client = cloud_logging.Client()
cl_logger = log_client.logger("hw4-file-server")


def log_event(severity, message, **fields):
    """Structured log + simple print for erroneous requests."""
    cl_logger.log_struct({"message": message, **fields}, severity=severity)
    print(f"{severity}: {message} | {json.dumps(fields)}", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "hw4-file-server"

    def send_body(self, status, body, content_type="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":  # HEAD responses must not carry a body
            self.wfile.write(body)

    # --- GET / POST ---
    def do_GET(self):
        self.serve_file(unquote(urlsplit(self.path).path).lstrip("/"))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode(errors="replace").strip()
        try:
            data = json.loads(raw)
        except ValueError:
            data = None
        if isinstance(data, dict) and data.get("file"):
            filename = str(data["file"]).strip()
        elif raw.startswith("file="):
            filename = parse_qs(raw).get("file", [""])[0].strip()
        else:
            filename = raw
        self.serve_file(filename.lstrip("/"))

    # --- every other method -> 501 ---
    def not_implemented(self):
        log_event("ERROR", "Method not implemented", method=self.command,
                  path=self.path, status=501)
        self.send_body(501, f"501 Not Implemented: {self.command}\n")

    do_PUT = do_DELETE = do_HEAD = do_CONNECT = not_implemented
    do_OPTIONS = do_TRACE = do_PATCH = not_implemented

    def serve_file(self, filename):
        method = self.command

        # --- export-control check ---
        country = self.headers.get("X-country", "").strip()
        if country.lower() in FORBIDDEN_COUNTRIES:
            event = {
                "country": country,
                "file": filename,
                "method": method,
                "time": datetime.datetime.utcnow().isoformat() + "Z",
            }
            log_event("CRITICAL", "Forbidden country request", status=400, **event)
            try:
                publisher.publish(topic_path, json.dumps(event).encode()).result(timeout=10)
            except Exception as e:  # don't let a Pub/Sub hiccup change the response
                log_event("ERROR", "Failed to publish to Pub/Sub", error=str(e))
            self.send_body(400, "400 Permission denied: export to your country is prohibited\n")
            return

        # --- serve the file or 404 ---
        if not filename:
            log_event("WARNING", "No file requested", method=method, status=404)
            self.send_body(404, "404 Not Found: no file specified\n")
            return

        try:
            blob = bucket.get_blob(filename)  # None if missing
            if blob is None:
                log_event("WARNING", "File not found", file=filename,
                          method=method, status=404)
                self.send_body(404, f"404 Not Found: {filename}\n")
                return
            body = blob.download_as_bytes()
            self.send_body(200, body, blob.content_type or "application/octet-stream")
        except Exception as e:
            log_event("ERROR", "Unexpected error", file=filename, error=str(e), status=500)
            self.send_body(500, "500 Internal Server Error\n")


if __name__ == "__main__":
    print(f"Serving gs://{BUCKET} on port {PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
