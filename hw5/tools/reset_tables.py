"""
Empties both HW5 tables (before the curl demo and before the full load test).
Asks for confirmation unless --yes is given.

Usage: hw5/.venv/bin/python tools/reset_tables.py [--yes]
"""
import sys

import sqlalchemy

import db


def main():
    if "--yes" not in sys.argv:
        answer = input(f"Delete ALL rows from requests and failed_requests in "
                       f"{db.INSTANCE_CONNECTION_NAME}/{db.DB_NAME}? Type YES: ")
        if answer.strip() != "YES":
            print("Aborted.")
            return
    engine = db.make_engine()
    with engine.begin() as conn:
        for table in ("requests", "failed_requests"):
            conn.execute(sqlalchemy.text(f"TRUNCATE TABLE {table}"))
            print(f"Truncated {table}")
    engine.dispose()


if __name__ == "__main__":
    main()
