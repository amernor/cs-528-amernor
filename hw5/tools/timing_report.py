"""
Part 6: summarizes the web server's per-request timings (timings.csv written
by service1, copied from hw5-web:/var/lib/service1/timings.csv).

For each timed step (parse, gcs, send, db) and the total: count, mean,
median, p95, p99 and max in milliseconds, overall and split into 200 vs
non-200 requests. Prints a markdown report and writes it to
report/timings.md.

Usage: python3 tools/timing_report.py timings.csv [--since "2026-10-27T03:00:00"]
       (--since is a UTC timestamp; only rows at or after it are used)
"""
import argparse
import csv
import os
import statistics

STEPS = [
    ("parse", "(a) process request + extract headers"),
    ("gcs", "(b) read file from Cloud Storage"),
    ("send", "(c) send response"),
    ("db", "(d) insert into Cloud SQL"),
]


def percentile(sorted_values, p):
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


def summarize(values_ns):
    ms = sorted(v / 1e6 for v in values_ns)
    if not ms:
        return None
    return {
        "n": len(ms), "mean": statistics.fmean(ms), "median": percentile(ms, 50),
        "p95": percentile(ms, 95), "p99": percentile(ms, 99), "max": ms[-1],
    }


def table(rows, title):
    lines = [f"### {title}", "",
             "| Step | Requests | Mean (ms) | Median (ms) | p95 (ms) | p99 (ms) | Max (ms) |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for label, key in [(desc, name) for name, desc in STEPS] + [("Total of the four steps", "total")]:
        s = summarize([r[key] for r in rows if r[key] is not None])
        if s is None:
            lines.append(f"| {label} | 0 | – | – | – | – | – |")
        else:
            lines.append(f"| {label} | {s['n']:,} | {s['mean']:.2f} | {s['median']:.2f} | "
                         f"{s['p95']:.2f} | {s['p99']:.2f} | {s['max']:.2f} |")
    return "\n".join(lines) + "\n"


def load(path, since):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r["ts_utc"] == "ts_utc" or (since and r["ts_utc"] < since):
                continue
            row = {"status": int(r["status"])}
            for name, _ in STEPS:
                row[name] = int(r[f"{name}_ns"]) if r[f"{name}_ns"] else None
            row["total"] = sum(row[name] or 0 for name, _ in STEPS)
            rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--since", help="UTC timestamp (ISO), e.g. 2026-10-27T03:00:00")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  "..", "report", "timings.md"))
    args = ap.parse_args()

    rows = load(args.csv, args.since)
    by_status = {}
    for r in rows:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
    report = [
        "## Part 6: server-side timings",
        "",
        f"Source: `{os.path.basename(args.csv)}`"
        + (f", rows since {args.since} UTC" if args.since else "")
        + f". {len(rows):,} requests ("
        + ", ".join(f"{s}: {n:,}" for s, n in sorted(by_status.items())) + ").",
        "Measured with `time.perf_counter_ns()` around each step's function. "
        "Steps that do not run for a request (no Cloud Storage read for 400/501) are left out of that step's statistics.",
        "",
        table(rows, "All requests"),
        table([r for r in rows if r["status"] == 200], "Successful requests (200)"),
        table([r for r in rows if r["status"] != 200], "Failed requests (non-200)"),
    ]
    text = "\n".join(report)
    print(text)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(text)
    print(f"(written to {os.path.relpath(args.out)})")


if __name__ == "__main__":
    main()
