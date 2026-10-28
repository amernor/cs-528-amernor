"""
Shared connection helper for setup_schema.py and the tools/ scripts (run
from a laptop, not the VM).

Connects through the Cloud SQL Python Connector, authenticated with
Application Default Credentials (`gcloud auth application-default login`),
so no IP allowlisting or SSL certificates are needed. The app user's
password is read from Secret Manager; it is never stored locally.

Settings come from the environment (setup.sh exports them), with the HW5
defaults as a fallback so the tools can be run on their own.
"""
import atexit
import os

import sqlalchemy
from google.cloud import secretmanager
from google.cloud.sql.connector import Connector

PROJECT_ID = os.environ.get("PROJECT_ID", "superb-heaven-507521-u2")
INSTANCE_CONNECTION_NAME = os.environ.get(
    "INSTANCE_CONNECTION_NAME", f"{PROJECT_ID}:us-central1:hw5-db")
DB_NAME = os.environ.get("DB_NAME", "hw5")
DB_USER = os.environ.get("DB_USER", "webapp")
DB_PASSWORD_SECRET = os.environ.get("DB_PASSWORD_SECRET", "hw5-db-password")


def get_password(project=PROJECT_ID, secret=DB_PASSWORD_SECRET):
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project}/secrets/{secret}/versions/latest"
    return client.access_secret_version(name=name).payload.data.decode().strip()


def make_engine(**engine_kwargs):
    """SQLAlchemy engine whose connections come from the Cloud SQL connector."""
    connector = Connector()
    atexit.register(connector.close)  # stop its background refresh thread on exit
    password = get_password()

    def getconn():
        return connector.connect(INSTANCE_CONNECTION_NAME, "pymysql",
                                 user=DB_USER, password=password, db=DB_NAME)

    return sqlalchemy.create_engine("mysql+pymysql://", creator=getconn, **engine_kwargs)
