"""
HW6 Part 2: moves the HW5 data into the 3NF schema.

  1. sql/precheck_3nf.sql  checks the dependencies the design relies on
                           (client_ip -> country, country -> is_banned)
  2. sql/schema_3nf.sql    creates countries, client_ips, requests_3nf,
                           failed_requests_3nf (IF NOT EXISTS)
  3. sql/migrate_3nf.sql   INSERT ... SELECT from the HW5 tables
  4. sql/verify_3nf.sql    checks nothing was lost or changed

Idempotent: safe to re-run (run.sh runs it on the VM before training).
The HW5 tables are only read.

Usage:  python migrate_3nf.py          (env settings: see db.py)
"""
import os
import sys
import time

import sqlalchemy

import db

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.environ.get("SQL_DIR", os.path.join(HERE, "sql"))
NEW_TABLES = ["countries", "client_ips", "requests_3nf", "failed_requests_3nf"]


def run_checks(conn, filename):
    """Runs each SELECT in the file; all must return 0. Returns True if they do."""
    ok = True
    for stmt in db.sql_statements(os.path.join(SQL_DIR, filename)):
        row = conn.execute(sqlalchemy.text(stmt)).mappings().one()
        (name, value), = row.items()
        status = "ok" if value == 0 else "FAILED"
        ok &= value == 0
        print(f"  {name:<40} {value:>6}  {status}")
    return ok


def counts(conn, tables):
    return {t: conn.execute(sqlalchemy.text(f"SELECT COUNT(*) FROM `{t}`")).scalar()
            for t in tables}


def main():
    print(f"3NF migration on {db.INSTANCE_CONNECTION_NAME}/{db.DB_NAME}", flush=True)
    engine = db.make_engine()

    with engine.connect() as conn:
        print("\n[1/4] Pre-checks on the HW5 data (sql/precheck_3nf.sql)")
        if not run_checks(conn, "precheck_3nf.sql"):
            sys.exit("Pre-checks failed: the 3NF design does not fit this data")

    with engine.begin() as conn:
        print("\n[2/4] Creating the 3NF tables (sql/schema_3nf.sql)")
        for stmt in db.sql_statements(os.path.join(SQL_DIR, "schema_3nf.sql")):
            conn.execute(sqlalchemy.text(stmt))
        print("  " + ", ".join(NEW_TABLES))

    # one transaction: either all the data moves or none of it
    with engine.begin() as conn:
        print("\n[3/4] Copying the data (sql/migrate_3nf.sql)")
        for stmt in db.sql_statements(os.path.join(SQL_DIR, "migrate_3nf.sql")):
            t0 = time.time()
            n = conn.execute(sqlalchemy.text(stmt)).rowcount
            target = stmt.split()[3]  # INSERT IGNORE INTO <table>
            print(f"  {target:<22} +{n:>7} rows  ({time.time() - t0:.1f}s)")

    with engine.connect() as conn:
        print("\n[4/4] Verifying (sql/verify_3nf.sql)")
        ok = run_checks(conn, "verify_3nf.sql")
        print("\nRow counts:")
        for t, n in counts(conn, ["requests", "failed_requests"] + NEW_TABLES).items():
            print(f"  {t:<22} {n:>7}")
    engine.dispose()
    if not ok:
        sys.exit("Verification failed")
    print("\nMigration OK")


if __name__ == "__main__":
    main()
