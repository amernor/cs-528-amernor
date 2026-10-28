"""
Part 7: statistics over the requests in Cloud SQL. Prints each question with
its SQL and answer, and writes report/stats.md.

The provided client sends all six X-* headers on every request; internet
scanners that hit the public port send none. The answers therefore use only
rows that carry client headers (CLIENT_ROWS), and rows without them are
counted separately in the sanity checks.

Usage: hw5/.venv/bin/python tools/stats.py
"""
import os

import sqlalchemy

import db

CLIENT_ROWS = ("country IS NOT NULL AND client_ip IS NOT NULL AND gender IS NOT NULL"
               " AND age IS NOT NULL AND income IS NOT NULL AND time_of_day IS NOT NULL")

QUESTIONS = [
    ("How many requests were processed successfully vs unsuccessfully?",
     f"""SELECT IF(status_code = 200, 'successful (200)', 'unsuccessful (non-200)') AS outcome,
               COUNT(*) AS requests
        FROM requests WHERE {CLIENT_ROWS} GROUP BY outcome ORDER BY outcome"""),
    ("Breakdown of the unsuccessful requests by status code",
     f"""SELECT status_code, COUNT(*) AS requests
        FROM requests WHERE {CLIENT_ROWS} AND status_code <> 200
        GROUP BY status_code ORDER BY status_code"""),
    ("How many requests came from banned countries?",
     f"""SELECT COUNT(*) AS requests FROM requests WHERE {CLIENT_ROWS} AND is_banned"""),
    ("How many requests were made by Male vs Female users?",
     f"""SELECT gender, COUNT(*) AS requests
        FROM requests WHERE {CLIENT_ROWS} GROUP BY gender ORDER BY requests DESC"""),
    ("What were the top 5 countries sending requests?",
     f"""SELECT country, COUNT(*) AS requests
        FROM requests WHERE {CLIENT_ROWS}
        GROUP BY country ORDER BY requests DESC, country LIMIT 5"""),
    ("What age group issued the most requests?",
     f"""SELECT age, COUNT(*) AS requests
        FROM requests WHERE {CLIENT_ROWS} GROUP BY age ORDER BY requests DESC, age LIMIT 3"""),
    ("What income group issued the most requests?",
     f"""SELECT income, COUNT(*) AS requests
        FROM requests WHERE {CLIENT_ROWS}
        GROUP BY income ORDER BY requests DESC, income LIMIT 3"""),
]

CHECKS = [
    ("Client requests (all six headers present; used above)",
     f"SELECT COUNT(*) FROM requests WHERE {CLIENT_ROWS}"),
    ("Requests without client headers (internet scanners; excluded above)",
     f"SELECT COUNT(*) FROM requests WHERE NOT ({CLIENT_ROWS})"),
    ("Total rows in requests", "SELECT COUNT(*) FROM requests"),
    ("Rows in failed_requests", "SELECT COUNT(*) FROM failed_requests"),
    ("Non-200 rows in requests (should equal the line above)",
     "SELECT COUNT(*) FROM requests WHERE status_code <> 200"),
    ("First / last request (UTC)",
     "SELECT CONCAT(MIN(received_at), '  /  ', MAX(received_at)) FROM requests"),
]


def md_table(columns, rows):
    lines = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for r in rows:
        lines.append("| " + " | ".join(f"{v:,}" if isinstance(v, int) else str(v) for v in r) + " |")
    return "\n".join(lines)


def main():
    engine = db.make_engine()
    out = ["## Part 7: request statistics", ""]
    with engine.connect() as conn:
        for question, sql in QUESTIONS:
            result = conn.execute(sqlalchemy.text(sql))
            rows = result.fetchall()
            sql_clean = " ".join(sql.split())
            print(f"\n{question}\n  SQL: {sql_clean}")
            for r in rows:
                print("   ", *r)
            out += [f"### {question}", "", f"```sql\n{sql_clean}\n```", "",
                    md_table(list(result.keys()), rows), ""]
        out += ["### Sanity checks", ""]
        print("\nSanity checks:")
        for label, sql in CHECKS:
            value = conn.execute(sqlalchemy.text(sql)).scalar()
            print(f"  {label}: {value}")
            out.append(f"- {label}: **{value:,}**" if isinstance(value, int) else f"- {label}: {value}")
    engine.dispose()

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "report", "stats.md")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"\n(written to {os.path.relpath(path)})")


if __name__ == "__main__":
    main()
