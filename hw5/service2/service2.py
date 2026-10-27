"""
Service 2: runs on its own VM (started by startup/service2-startup.sh).

Pulls "forbidden request" messages that service 1 publishes to Pub/Sub and
prints an error message to standard output (view it on the VM with
`sudo journalctl -u service2 -f`).

Auth: the VM's attached service account, which only has
roles/pubsub.subscriber on the subscription. No key files or impersonation.
"""
import json
import os

from google.cloud import pubsub_v1

PROJECT_ID = os.environ["PROJECT_ID"]
SUBSCRIPTION = os.environ.get("SUBSCRIPTION", "forbidden-requests-sub")

subscriber = pubsub_v1.SubscriberClient()
sub_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION)


def callback(message):
    try:
        event = json.loads(message.data.decode())
        line = (f"[{event.get('time')}] FORBIDDEN request from "
                f"{event.get('country')}: {event.get('method')} "
                f"file={event.get('file')}")
    except Exception:
        line = f"FORBIDDEN request (unparseable): {message.data!r}"
    print(f"ERROR: {line}", flush=True)
    message.ack()


if __name__ == "__main__":
    print(f"Listening on {sub_path} ...", flush=True)
    future = subscriber.subscribe(sub_path, callback=callback)
    try:
        future.result()
    except KeyboardInterrupt:
        future.cancel()
