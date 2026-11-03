"""
HW6: makes sure the HW5 source tables exist and hold the HW5 data before the
3NF migration runs (startup-trainer.sh runs it on the VM first).

  1. CREATE TABLE IF NOT EXISTS requests / failed_requests (sql/hw5_schema.sql)
  2. requests has rows, no snapshot in the bucket yet
       -> save a snapshot: gs://$BUCKET/$DATA_PREFIX/{requests,failed_requests}.csv.gz
     requests is empty, snapshot exists
       -> restore both tables from the snapshot (original ids kept)
     requests is empty, no snapshot
       -> stop with an error (nothing to train on)

So a run against a database whose tables were dropped or emptied still works.

Env: BUCKET (cs528-amernor), DATA_PREFIX (hw6-data), plus db.py settings.
"""
import gzip
import io
import os
import sys

import pandas as pd
import sqlalchemy
from google.cloud import storage

import db

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.environ.get("SQL_DIR", os.path.join(HERE, "sql"))
BUCKET = os.environ.get("BUCKET", "cs528-amernor")
DATA_PREFIX = os.environ.get("DATA_PREFIX", "hw6-data").strip("/")
TABLES = ["requests", "failed_requests"]
BATCH = 5000


def count(conn, table):
    return conn.execute(sqlalchemy.text(f"SELECT COUNT(*) FROM `{table}`")).scalar()


def save_snapshot(engine, bucket):
    with engine.connect() as conn:
        for t in TABLES:
            df = pd.read_sql(sqlalchemy.text(f"SELECT * FROM `{t}` ORDER BY id"), conn)
            buf = io.BytesIO()
            with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
                gz.write(df.to_csv(index=False).encode())
            bucket.blob(f"{DATA_PREFIX}/{t}.csv.gz").upload_from_string(
                buf.getvalue(), content_type="application/gzip")
            print(f"  saved {len(df)} rows of {t} -> gs://{BUCKET}/{DATA_PREFIX}/{t}.csv.gz")


def restore_snapshot(engine, bucket):
    frames = {}
    for t in TABLES:
        data = bucket.blob(f"{DATA_PREFIX}/{t}.csv.gz").download_as_bytes()
        frames[t] = pd.read_csv(io.BytesIO(data), compression="gzip", dtype=str,
                                keep_default_na=False, na_values=[""])
    with engine.begin() as conn:  # all or nothing
        for t, df in frames.items():
            cols = list(df.columns)
            stmt = sqlalchemy.text(
                f"INSERT INTO `{t}` ({', '.join(f'`{c}`' for c in cols)}) "
                f"VALUES ({', '.join(':' + c for c in cols)})")
            rows = df.astype(object).where(df.notna(), None).to_dict("records")
            for i in range(0, len(rows), BATCH):
                conn.execute(stmt, rows[i:i + BATCH])
            print(f"  restored {len(rows)} rows into {t}")
    # fresh index statistics, so the optimizer plans the migration joins well
    with engine.connect() as conn:
        conn.execute(sqlalchemy.text(f"ANALYZE TABLE {', '.join(TABLES)}")).fetchall()


def main():
    print(f"Source tables on {db.INSTANCE_CONNECTION_NAME}/{db.DB_NAME}", flush=True)
    engine = db.make_engine()
    with engine.begin() as conn:
        for stmt in db.sql_statements(os.path.join(SQL_DIR, "hw5_schema.sql")):
            conn.execute(sqlalchemy.text(stmt))
    with engine.connect() as conn:
        n = {t: count(conn, t) for t in TABLES}
    print(f"  tables present: requests {n['requests']} rows, "
          f"failed_requests {n['failed_requests']} rows")

    bucket = storage.Client(project=db.PROJECT_ID).bucket(BUCKET)
    have_snapshot = all(bucket.blob(f"{DATA_PREFIX}/{t}.csv.gz").exists() for t in TABLES)

    if n["requests"] > 0:
        if have_snapshot:
            print(f"  data present; snapshot already in gs://{BUCKET}/{DATA_PREFIX}/")
        else:
            print("  data present; saving a snapshot")
            save_snapshot(engine, bucket)
    elif have_snapshot:
        if n["failed_requests"]:
            with engine.begin() as conn:  # orphans of an emptied requests table
                conn.execute(sqlalchemy.text("DELETE FROM failed_requests"))
        print(f"  requests is empty; restoring from gs://{BUCKET}/{DATA_PREFIX}/")
        restore_snapshot(engine, bucket)
    else:
        sys.exit("requests is empty and there is no snapshot to restore: "
                 "populate the database with the HW5 load test first")
    engine.dispose()
    print("Source data OK")


if __name__ == "__main__":
    main()
