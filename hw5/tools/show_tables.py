"""
Prints the row count and the latest rows of both HW5 tables (used for the
curl demo screenshots).

Usage: hw5/.venv/bin/python tools/show_tables.py [N]     (default N = 10)
"""
import sys

import sqlalchemy

import db

QUERIES = {
    "requests": """SELECT id, received_at, country, client_ip, gender, age, income,
                          is_banned, time_of_day, requested_file, method, status_code
                   FROM requests ORDER BY id DESC LIMIT :n""",
    "failed_requests": """SELECT id, time_of_request, requested_file, error_code
                          FROM failed_requests ORDER BY id DESC LIMIT :n""",
}


def fmt(value):
    if value is None:
        return "NULL"
    if hasattr(value, "isoformat"):
        return value.isoformat(sep=" ", timespec="seconds")
    return str(value)


def print_table(columns, rows):
    cells = [[fmt(v) for v in row] for row in rows]
    widths = [max([len(c)] + [len(r[i]) for r in cells]) for i, c in enumerate(columns)]
    line = "+" + "+".join("-" * (w + 2) for w in widths) + "+"
    print(line)
    print("| " + " | ".join(c.ljust(w) for c, w in zip(columns, widths)) + " |")
    print(line)
    for r in cells:
        print("| " + " | ".join(v.ljust(w) for v, w in zip(r, widths)) + " |")
    if cells:
        print(line)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    engine = db.make_engine()
    with engine.connect() as conn:
        for table, query in QUERIES.items():
            count = conn.execute(sqlalchemy.text(f"SELECT COUNT(*) FROM {table}")).scalar()
            result = conn.execute(sqlalchemy.text(query), {"n": n})
            rows = list(reversed(result.fetchall()))
            shown = f", latest {len(rows)} shown" if count > len(rows) else ""
            print(f"\n{table}: {count} row(s){shown}")
            print_table(list(result.keys()), rows)
    engine.dispose()


if __name__ == "__main__":
    main()
