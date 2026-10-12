import json
import os
import datetime
from urllib.parse import parse_qs

import functions_framework
from flask import Response
from google.cloud import storage, pubsub_v1
from google.cloud import logging as cloud_logging

BUCKET = os.environ.get("BUCKET", "cs528-amernor")
TOPIC = os.environ.get("TOPIC", "forbidden-requests")

FORBIDDEN_COUNTRIES = {
    c.lower()
    for c in [
        "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
        "Libya", "Sudan", "Zimbabwe", "Syria",
    ]
}

storage_client = storage.Client()
PROJECT_ID = os.environ.get("PROJECT_ID", storage_client.project)
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC)

# Structured logging client (entries show up as jsonPayload in Cloud Logging)
log_client = cloud_logging.Client()
cl_logger = log_client.logger("hw-file-server")


def log_error(message, **fields):
    """Structured log + simple print for erroneous requests."""
    cl_logger.log_struct({"message": message, **fields}, severity="ERROR")
    print(f"ERROR: {message} | {json.dumps(fields)}")


def extract_filename(request):
    """GET: file is in the path. POST: file is in the payload."""
    if request.method == "GET":
        return request.path.lstrip("/")

    # POST: accept JSON {"file": "..."}, form-style "file=...", or raw text
    data = request.get_json(silent=True)
    if isinstance(data, dict) and data.get("file"):
        return str(data["file"]).strip().lstrip("/")
    raw = request.get_data(as_text=True).strip()
    if raw.startswith("file="):
        return parse_qs(raw).get("file", [""])[0].strip().lstrip("/")
    return raw.lstrip("/")


@functions_framework.http
def handle_request(request):
    method = request.method

    # --- Step 3: anything other than GET/POST -> 501 ---
    if method not in ("GET", "POST"):
        log_error("Method not implemented", method=method,
                  path=request.path, status=501)
        return Response(f"501 Not Implemented: {method}\n", status=501)

    filename = extract_filename(request)

    # --- Step 7: export-control check ---
    country = request.headers.get("X-country", "").strip()
    if country.lower() in FORBIDDEN_COUNTRIES:
        event = {
            "country": country,
            "file": filename,
            "method": method,
            "time": datetime.datetime.utcnow().isoformat() + "Z",
        }
        log_error("Forbidden country request", status=400, **event)
        try:
            publisher.publish(topic_path, json.dumps(event).encode()).result(timeout=10)
        except Exception as e:  # don't let a Pub/Sub hiccup change the response
            log_error("Failed to publish to Pub/Sub", error=str(e))
        return Response("400 Permission denied: export to your country is prohibited\n",
                        status=400)

    # --- Steps 1-2: serve the file or 404 ---
    if not filename:
        log_error("No file requested", method=method, status=404)
        return Response("404 Not Found: no file specified\n", status=404)

    try:
        blob = storage_client.bucket(BUCKET).get_blob(filename)  # None if missing
        if blob is None:
            log_error("File not found", file=filename, method=method, status=404)
            return Response(f"404 Not Found: {filename}\n", status=404)
        body = blob.download_as_bytes()
        return Response(body, status=200,
                        content_type=blob.content_type or "application/octet-stream")
    except Exception as e:
        log_error("Unexpected error", file=filename, error=str(e), status=500)
        return Response("500 Internal Server Error\n", status=500)
