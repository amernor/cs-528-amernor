"""
Service 1: web server running on a VM (started by startup.sh).

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

HW5: every request is also written to Cloud SQL (table `requests`, plus
`failed_requests` for non-200s) with the client's X-* headers, and four steps
are timed with time.perf_counter_ns(), each in its own function:
  parse_request  (a) process the request, extract the headers
  read_file      (b) read the file from Cloud Storage
  send_response  (c) send the response to the client
  log_to_db      (d) insert the rows into the database
One CSV row per request goes to TIMINGS_PATH (tools/timing_report.py).
The DB insert runs after the response is sent, so it does not add to the
client's latency; a DB failure is logged and never changes the response.

Auth: the VM's attached service account (no key files).
"""
import csv
import datetime
import json
import os
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional
from urllib.parse import parse_qs, unquote, urlsplit

import sqlalchemy
from google.cloud import storage, pubsub_v1, secretmanager
from google.cloud import logging as cloud_logging
from google.cloud.sql.connector import Connector

BUCKET = os.environ.get("BUCKET", "cs528-amernor")
TOPIC = os.environ.get("TOPIC", "forbidden-requests")
PORT = int(os.environ.get("PORT", "8080"))
INSTANCE_CONNECTION_NAME = os.environ.get("INSTANCE_CONNECTION_NAME", "")
DB_NAME = os.environ.get("DB_NAME", "hw5")
DB_USER = os.environ.get("DB_USER", "webapp")
DB_PASSWORD_SECRET = os.environ.get("DB_PASSWORD_SECRET", "hw5-db-password")
TIMINGS_PATH = os.environ.get("TIMINGS_PATH", "")
LOG_HEADERS = os.environ.get("LOG_HEADERS") == "1"  # debug: print every request's headers

TEXT = "text/plain; charset=utf-8"

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
cl_logger = log_client.logger("hw5-file-server")


def log_event(severity, message, **fields):
    """Structured log + simple print for erroneous requests."""
    cl_logger.log_struct({"message": message, **fields}, severity=severity)
    print(f"{severity}: {message} | {json.dumps(fields, default=str)}", flush=True)


# --- request data -----------------------------------------------------------

@dataclass
class RequestInfo:
    method: str
    path: str
    filename: str
    country: Optional[str]
    client_ip: Optional[str]
    gender: Optional[str]
    age: Optional[str]
    income: Optional[str]
    time_of_day: Optional[datetime.datetime]
    is_banned: bool
    received_at: datetime.datetime


def header_value(headers, name, max_len):
    """Stripped header value cut to its column width, or None if missing/empty."""
    value = (headers.get(name) or "").strip()
    return value[:max_len] or None


def parse_client_time(value):
    """X-time looks like '2026-10-26 08:00:00'; None if missing or malformed."""
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    except (TypeError, ValueError):
        return None


def is_banned_country(country):
    return (country or "").lower() in FORBIDDEN_COUNTRIES


def filename_from_body(raw):
    try:
        data = json.loads(raw)
    except ValueError:
        data = None
    if isinstance(data, dict) and data.get("file"):
        return str(data["file"]).strip()
    if raw.startswith("file="):
        return parse_qs(raw).get("file", [""])[0].strip()
    return raw


# --- the four timed steps -----------------------------------------------------

def parse_request(handler):
    """(a) Extract the requested file and the client's X-* headers."""
    received_at = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if handler.command == "POST":
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length).decode(errors="replace").strip()
        filename = filename_from_body(raw)
    else:
        filename = unquote(urlsplit(handler.path).path)
    if LOG_HEADERS:
        print(f"HEADERS {handler.command} {handler.path} {json.dumps(dict(handler.headers))}", flush=True)

    h = handler.headers
    country = header_value(h, "X-country", 64)
    return RequestInfo(
        method=handler.command,
        path=handler.path,
        filename=filename.lstrip("/")[:512],
        country=country,
        client_ip=header_value(h, "X-client-IP", 45),
        gender=header_value(h, "X-gender", 16),
        age=header_value(h, "X-age", 16),
        income=header_value(h, "X-income", 32),
        time_of_day=parse_client_time(header_value(h, "X-time", 32)),
        is_banned=is_banned_country(country),
        received_at=received_at,
    )


def read_file(filename):
    """(b) Fetch the file from Cloud Storage -> (status, body, content type)."""
    if not filename:
        return 404, "404 Not Found: no file specified\n", TEXT
    try:
        blob = bucket.get_blob(filename)  # None if missing
        if blob is None:
            return 404, f"404 Not Found: {filename}\n", TEXT
        return 200, blob.download_as_bytes(), blob.content_type or "application/octet-stream"
    except Exception as e:
        log_event("ERROR", "Unexpected error", file=filename, error=str(e), status=500)
        return 500, "500 Internal Server Error\n", TEXT


def send_response(handler, status, body, content_type):
    """(c) Write the status line, headers and body to the client."""
    if isinstance(body, str):
        body = body.encode()
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if handler.command != "HEAD":  # HEAD responses must not carry a body
        handler.wfile.write(body)


INSERT_REQUEST = sqlalchemy.text("""
    INSERT INTO requests (received_at, country, client_ip, gender, age, income,
                          is_banned, time_of_day, requested_file, method, status_code)
    VALUES (:received_at, :country, :client_ip, :gender, :age, :income,
            :is_banned, :time_of_day, :requested_file, :method, :status_code)
""")
INSERT_FAILED = sqlalchemy.text("""
    INSERT INTO failed_requests (time_of_request, requested_file, error_code)
    VALUES (:time_of_request, :requested_file, :error_code)
""")


def log_to_db(info, status):
    """(d) Insert the request (and, if it failed, its error row) in one transaction."""
    engine = get_engine()
    if engine is None:
        return
    try:
        with engine.begin() as conn:
            conn.execute(INSERT_REQUEST, {
                "received_at": info.received_at,
                "country": info.country,
                "client_ip": info.client_ip,
                "gender": info.gender,
                "age": info.age,
                "income": info.income,
                "is_banned": info.is_banned,
                "time_of_day": info.time_of_day,
                "requested_file": info.filename,
                "method": info.method[:10],
                "status_code": status,
            })
            if status != 200:
                conn.execute(INSERT_FAILED, {
                    "time_of_request": info.received_at,
                    "requested_file": info.filename,
                    "error_code": status,
                })
    except Exception as e:  # never let the DB change the response or kill the thread
        log_event("ERROR", "Database insert failed", file=info.filename,
                  status=status, error=str(e))


# --- database engine ------------------------------------------------------------

_engine = None
_engine_lock = threading.Lock()
_engine_retry_at = 0.0


def make_engine():
    """Connection pool to Cloud SQL via the Python connector (VM service account)."""
    secret = secretmanager.SecretManagerServiceClient()
    name = f"projects/{PROJECT_ID}/secrets/{DB_PASSWORD_SECRET}/versions/latest"
    password = secret.access_secret_version(name=name).payload.data.decode().strip()
    connector = Connector()

    def getconn():
        return connector.connect(INSTANCE_CONNECTION_NAME, "pymysql",
                                 user=DB_USER, password=password, db=DB_NAME)

    return sqlalchemy.create_engine(
        "mysql+pymysql://", creator=getconn,
        pool_size=10, max_overflow=10, pool_pre_ping=True, pool_recycle=1800,
    )


def get_engine():
    """The shared engine, created on first use; retried at most every 30s if it fails."""
    global _engine, _engine_retry_at
    if _engine is not None or not INSTANCE_CONNECTION_NAME:
        return _engine
    with _engine_lock:
        if _engine is None and time.monotonic() >= _engine_retry_at:
            try:
                _engine = make_engine()
            except Exception as e:
                _engine_retry_at = time.monotonic() + 30
                log_event("ERROR", "Could not set up the database connection", error=str(e))
    return _engine


# --- timings ----------------------------------------------------------------------

TIMING_COLUMNS = ["ts_utc", "method", "status", "parse_ns", "gcs_ns", "send_ns", "db_ns"]
_timings_lock = threading.Lock()
_timings_writer = None
if TIMINGS_PATH:
    _timings_file = open(TIMINGS_PATH, "a", buffering=1, newline="")  # line-buffered
    _timings_writer = csv.writer(_timings_file)
    if _timings_file.tell() == 0:
        _timings_writer.writerow(TIMING_COLUMNS)


def timed(fn, *args):
    """Run fn(*args) -> (result, elapsed nanoseconds)."""
    start = time.perf_counter_ns()
    result = fn(*args)
    return result, time.perf_counter_ns() - start


def record_timing(info, status, parse_ns, gcs_ns, send_ns, db_ns):
    """One CSV row per request; a skipped step is left empty."""
    if _timings_writer is None:
        return
    row = [info.received_at.isoformat(), info.method, status,
           parse_ns, "" if gcs_ns is None else gcs_ns, send_ns, db_ns]
    with _timings_lock:
        _timings_writer.writerow(row)


# --- HTTP handler ------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "hw5-file-server"

    def handle_request(self):
        info, parse_ns = timed(parse_request, self)
        gcs_ns = None

        if info.method not in ("GET", "POST"):
            # --- every other method -> 501 ---
            log_event("ERROR", "Method not implemented", method=info.method,
                      path=info.path, status=501)
            status, body, ctype = 501, f"501 Not Implemented: {info.method}\n", TEXT

        elif info.is_banned:
            # --- export-control check ---
            event = {
                "country": info.country,
                "file": info.filename,
                "method": info.method,
                "time": info.received_at.isoformat() + "Z",
            }
            log_event("CRITICAL", "Forbidden country request", status=400, **event)
            try:
                publisher.publish(topic_path, json.dumps(event).encode()).result(timeout=10)
            except Exception as e:  # don't let a Pub/Sub hiccup change the response
                log_event("ERROR", "Failed to publish to Pub/Sub", error=str(e))
            status, body, ctype = 400, "400 Permission denied: export to your country is prohibited\n", TEXT

        else:
            # --- serve the file or 404 ---
            (status, body, ctype), gcs_ns = timed(read_file, info.filename)
            if status == 404:
                log_event("WARNING", "File not found", file=info.filename,
                          method=info.method, status=404)

        try:
            _, send_ns = timed(send_response, self, status, body, ctype)
        except OSError as e:  # client went away; still record the request
            send_ns = ""
            print(f"WARNING: could not send response: {e}", flush=True)

        _, db_ns = timed(log_to_db, info, status)
        record_timing(info, status, parse_ns, gcs_ns, send_ns, db_ns)

    do_GET = do_POST = handle_request
    do_PUT = do_DELETE = do_HEAD = do_CONNECT = handle_request
    do_OPTIONS = do_TRACE = do_PATCH = handle_request


if __name__ == "__main__":
    print(f"Serving gs://{BUCKET} on port {PORT}, DB {INSTANCE_CONNECTION_NAME or '(disabled)'}", flush=True)
    get_engine()  # connect early so the first request is not slower
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
