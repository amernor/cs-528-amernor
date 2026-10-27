"""
Creates the HW5 schema in Cloud SQL. Called by setup.sh right after the
database is created; safe to re-run (CREATE TABLE IF NOT EXISTS).

  requests         one row per request the web server receives (every
                   status code), with the client's X-* header values
  failed_requests  one extra row per non-200 request: only the time,
                   requested file and error code

Header -> column mapping (see report/headers-sample.jsonl):
  X-country -> country      X-gender -> gender    X-income -> income
  X-client-IP -> client_ip  X-age -> age          X-time -> time_of_day
  is_banned is computed by the server from the country.

Usage (from anywhere; setup.sh uses hw5/.venv):
  python setup_schema.py
Settings: PROJECT_ID, INSTANCE_CONNECTION_NAME, DB_NAME, DB_USER,
DB_PASSWORD_SECRET env vars (defaults in tools/db.py).
"""
import os
import sys

import sqlalchemy

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
import db  # noqa: E402

TABLES = [
    """
    CREATE TABLE IF NOT EXISTS requests (
      id             BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
      received_at    DATETIME(6)  NOT NULL,
      country        VARCHAR(64),
      client_ip      VARCHAR(45),
      gender         VARCHAR(16),
      age            VARCHAR(16),
      income         VARCHAR(32),
      is_banned      BOOLEAN      NOT NULL,
      time_of_day    DATETIME,
      requested_file VARCHAR(512),
      method         VARCHAR(10),
      status_code    SMALLINT     NOT NULL,
      INDEX idx_country (country),
      INDEX idx_status (status_code)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS failed_requests (
      id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
      time_of_request DATETIME(6)  NOT NULL,
      requested_file  VARCHAR(512),
      error_code      SMALLINT     NOT NULL
    )
    """,
]


def main():
    print(f"Creating schema in {db.INSTANCE_CONNECTION_NAME}/{db.DB_NAME} as {db.DB_USER}")
    engine = db.make_engine()
    with engine.begin() as conn:
        for ddl in TABLES:
            conn.execute(sqlalchemy.text(ddl))
    with engine.connect() as conn:
        tables = [r[0] for r in conn.execute(sqlalchemy.text("SHOW TABLES"))]
        print("Tables:", ", ".join(tables))
        for t in tables:
            print(f"\n{t}:")
            for col in conn.execute(sqlalchemy.text(f"DESCRIBE `{t}`")):
                print("  {:<16} {:<20} null={:<4} key={}".format(*col[:4]))
    engine.dispose()


if __name__ == "__main__":
    main()
