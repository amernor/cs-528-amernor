"""
Part 7: statistics over all requests in Cloud SQL. Prints each question with
its SQL and answer, and writes report/stats.md.

Usage: hw5/.venv/bin/python tools/stats.py
"""
import os

import sqlalchemy

import db

QUESTIONS = [
    ("How many requests were processed successfully vs unsuccessfully?",
     """SELECT IF(status_code = 200, 'successful (200)', 'unsuccessful (non-200)') AS outcome,
               COUNT(*) AS requests
        FROM requests GROUP BY outcome ORDER BY outcome"""),
    ("Breakdown of the unsuccessful requests by status code",
     """SELECT status_code, COUNT(*) AS requests
        FROM requests WHERE status_code <> 200 GROUP BY status_code ORDER BY status_code"""),
    ("How many requests came from banned countries?",
     """SELECT COUNT(*) AS requests FROM requests WHERE is_banned"""),
    ("How many requests were made by Male vs Female users?",
     """SELECT gender, COUNT(*) AS requests
        FROM requests GROUP BY gender ORDER BY requests DESC"""),
    ("What were the top 5 countries sending requests?",
     """SELECT country, COUNT(*) AS requests
        FROM requests GROUP BY country ORDER BY requests DESC, country LIMIT 5"""),
    ("What age group issued the most requests?",
     """SELECT age, COUNT(*) AS requests
        FROM requests GROUP BY age ORDER BY requests DESC, age LIMIT 3"""),
    ("What income group issued the most requests?",
     """SELECT income, COUNT(*) AS requests
        FROM requests GROUP BY income ORDER BY requests DESC, income LIMIT 3"""),
]

CHECKS = [
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
