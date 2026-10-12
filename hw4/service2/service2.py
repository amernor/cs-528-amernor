"""
Service 2: runs on your LOCAL laptop.

Pulls "forbidden request" messages from Pub/Sub, prints an error to stdout,
and appends the message to forbidden-logs/forbidden_requests.txt in the bucket.

Auth: service account IMPERSONATION with no key file and no
`gcloud auth application-default login`. We ask gcloud (logged in with plain
`gcloud auth login`) for a short-lived access token for the service account:

    gcloud auth print-access-token --impersonate-service-account=<SA_EMAIL>

Under the hood gcloud calls the IAM Credentials API (generateAccessToken).
This only works if your own user has roles/iam.serviceAccountTokenCreator
on the service account. The token expires after ~1 hour, and the credentials
class below simply asks gcloud for a new one when that happens.
"""
import datetime
import json
import os
import subprocess
import threading

import google.auth.credentials
from google.cloud import pubsub_v1, storage

PROJECT_ID = os.environ["PROJECT_ID"]
SA_EMAIL = os.environ["SA_EMAIL"]
BUCKET = os.environ.get("BUCKET", "cs528-amernor")
SUBSCRIPTION = os.environ.get("SUBSCRIPTION", "forbidden-requests-sub")
LOG_OBJECT = "forbidden-logs/forbidden_requests.txt"
_append_lock = threading.Lock()  # callbacks run on a thread pool


class GcloudImpersonatedCredentials(google.auth.credentials.Credentials):
    """Short-lived tokens for SA_EMAIL obtained via gcloud impersonation."""

    def __init__(self, sa_email):
        super().__init__()
        self._sa = sa_email
        self.refresh(None)

    def refresh(self, request):
        token = subprocess.check_output(
            ["gcloud", "auth", "print-access-token",
             f"--impersonate-service-account={self._sa}"],
            text=True,
        ).strip()
        self.token = token
        # gcloud tokens last 1h; refresh a bit early
        self.expiry = datetime.datetime.utcnow() + datetime.timedelta(minutes=50)


creds = GcloudImpersonatedCredentials(SA_EMAIL)
storage_client = storage.Client(project=PROJECT_ID, credentials=creds)
subscriber = pubsub_v1.SubscriberClient(credentials=creds)
sub_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION)


def append_to_bucket(line):
    """GCS objects are immutable, so 'append' = read, add line, re-upload."""
    with _append_lock:
        bucket = storage_client.bucket(BUCKET)
        # get_blob fetches current metadata, so the download below is pinned to
        # the latest generation; the bucket is public and a plain download can
        # return a cached (stale) copy, which would overwrite earlier lines
        blob = bucket.get_blob(LOG_OBJECT)
        if blob is None:
            blob, existing, generation = bucket.blob(LOG_OBJECT), "", 0
        else:
            existing, generation = blob.download_as_text(), blob.generation
        blob.cache_control = "no-store"
        # fail (and let Pub/Sub redeliver) if the file changed since we read it
        blob.upload_from_string(existing + line + "\n", content_type="text/plain",
                                if_generation_match=generation)


def callback(message):
    try:
        event = json.loads(message.data.decode())
        line = (f"[{event.get('time')}] FORBIDDEN request from "
                f"{event.get('country')}: {event.get('method')} "
                f"file={event.get('file')}")
    except Exception:
        line = f"FORBIDDEN request (unparseable): {message.data!r}"
    print(f"ERROR: {line}", flush=True)
    append_to_bucket(line)
    message.ack()


if __name__ == "__main__":
    print(f"Listening on {sub_path} as {SA_EMAIL} ...", flush=True)
    future = subscriber.subscribe(sub_path, callback=callback)
    try:
        future.result()
    except KeyboardInterrupt:
        future.cancel()
