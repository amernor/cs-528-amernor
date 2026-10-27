"""
Cloud Function (2nd gen, HTTP): stops the HW5 Cloud SQL instance if it is
running. Cloud Scheduler job hw5-db-check calls it at the top of every hour
(authenticated with an OIDC token for the hw5-db-stopper service account).

"Running" means activationPolicy == ALWAYS; stopping sets it to NEVER, which
is what `gcloud sql instances patch --activation-policy NEVER` does. The
patch is only started, not waited for, so the function returns quickly.

Pause the job while working with the DB:  tools/scheduler.sh pause|resume
"""
import os

import functions_framework
from googleapiclient import discovery

PROJECT_ID = os.environ.get("PROJECT_ID", "superb-heaven-507521-u2")
DB_INSTANCE = os.environ.get("DB_INSTANCE", "hw5-db")


@functions_framework.http
def stop_db_if_running(request):
    sqladmin = discovery.build("sqladmin", "v1beta4", cache_discovery=False)
    instance = sqladmin.instances().get(project=PROJECT_ID, instance=DB_INSTANCE).execute()
    policy = instance.get("settings", {}).get("activationPolicy")
    state = instance.get("state")

    if policy == "ALWAYS":
        sqladmin.instances().patch(
            project=PROJECT_ID, instance=DB_INSTANCE,
            body={"settings": {"activationPolicy": "NEVER"}},
        ).execute()
        message = f"{DB_INSTANCE}: activationPolicy ALWAYS -> set NEVER (state was {state})"
    else:
        message = f"{DB_INSTANCE}: activationPolicy {policy}, state {state} -> nothing to do"

    print(message, flush=True)
    return message + "\n"
