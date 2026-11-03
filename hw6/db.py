"""
Connection helper shared by migrate_3nf.py and train_models.py (same approach
as hw5/tools/db.py).

Connects through the Cloud SQL Python Connector with Application Default
Credentials: on a laptop `gcloud auth application-default login`, on the VM
its attached service account. The app user's password is read from Secret
Manager and never stored.

Settings come from the environment, with the HW5 values as defaults.
"""
import atexit
import os
import re
import time

import sqlalchemy
from google.cloud import secretmanager
from google.cloud.sql.connector import Connector

PROJECT_ID = os.environ.get("PROJECT_ID", "superb-heaven-507521-u2")
INSTANCE_CONNECTION_NAME = os.environ.get(
    "INSTANCE_CONNECTION_NAME", f"{PROJECT_ID}:us-central1:hw5-db")
DB_NAME = os.environ.get("DB_NAME", "hw5")
DB_USER = os.environ.get("DB_USER", "webapp")
DB_PASSWORD_SECRET = os.environ.get("DB_PASSWORD_SECRET", "hw5-db-password")


def get_password():
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{PROJECT_ID}/secrets/{DB_PASSWORD_SECRET}/versions/latest"
    return client.access_secret_version(name=name).payload.data.decode().strip()


def make_engine(attempts=10, wait=15):
    """SQLAlchemy engine over the connector. A freshly started Cloud SQL
    instance can report RUNNABLE while still dropping connections, so the
    first connection is retried."""
    connector = Connector()
    atexit.register(connector.close)
    password = get_password()

    def getconn():
        return connector.connect(INSTANCE_CONNECTION_NAME, "pymysql",
                                 user=DB_USER, password=password, db=DB_NAME)

    engine = sqlalchemy.create_engine("mysql+pymysql://", creator=getconn,
                                      pool_pre_ping=True)
    for i in range(1, attempts + 1):
        try:
            with engine.connect() as conn:
                conn.execute(sqlalchemy.text("SELECT 1"))
            return engine
        except sqlalchemy.exc.OperationalError as e:
            if i == attempts:
                raise
            print(f"  DB not ready (attempt {i}/{attempts}): {e.orig}; retrying in {wait}s",
                  flush=True)
            time.sleep(wait)


def sql_statements(path):
    """The statements of a .sql file (comments dropped, split on ';')."""
    with open(path) as f:
        text = re.sub(r"--[^\n]*", "", f.read())
    return [s.strip() for s in text.split(";") if s.strip()]
