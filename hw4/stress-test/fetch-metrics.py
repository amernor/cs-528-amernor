"""
Pulls peak resource usage of the web server VM for each stress-test run from
Cloud Monitoring (the same data as the console's Observability charts) and
prints a table. Run it on your laptop after copying the results folder back:

    gcloud compute scp --recurse hw4-client:~/results stress-test/ --zone us-central1-a
    python3 stress-test/fetch-metrics.py stress-test/results

Each run's window comes from its summary.txt (Start/End). Writes
report/metrics.csv, which report/plot_performance.py reads.

Needs only the standard library plus a logged-in gcloud. Monitoring data can
lag a few minutes behind, so wait ~5 minutes after the last run.
"""
import csv
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

PROJECT_ID = os.environ.get("PROJECT_ID", "superb-heaven-507521-u2")
ZONE = os.environ.get("ZONE", "us-central1-a")
VM = os.environ.get("VM", "hw4-web")
HERE = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(HERE, "..", "report", "metrics.csv")

# metric type, extra filter, aligner, scale to the unit we report
METRICS = {
    "cpu_pct": ("compute.googleapis.com/instance/cpu/utilization", "", "ALIGN_MAX", 100),
    "mem_pct": ("agent.googleapis.com/memory/percent_used",
                'metric.labels.state = "used"', "ALIGN_MAX", 1),
    "sent_mibps": ("compute.googleapis.com/instance/network/sent_bytes_count",
                   "", "ALIGN_RATE", 1 / 2**20),
    "recv_mibps": ("compute.googleapis.com/instance/network/received_bytes_count",
                   "", "ALIGN_RATE", 1 / 2**20),
}


def gcloud(*args):
    return subprocess.check_output(["gcloud", *args], text=True).strip()


def parse_summary(path):
    text = open(path).read()
    stamp = lambda label: datetime.datetime.strptime(
        re.search(rf"^{label}:\s+(.+) UTC$", text, re.M).group(1), "%Y-%m-%d %H:%M:%S"
    ).replace(tzinfo=datetime.timezone.utc)
    return {
        "clients": int(re.search(r"Summary: (\d+) client", text).group(1)),
        "start": stamp("Start"),
        "end": stamp("End"),
        "elapsed_s": int(re.search(r"^Elapsed: (\d+)s", text, re.M).group(1)),
        "errors": int(re.search(r"^Errors \(excluding 400s\): (\d+)", text, re.M).group(1)),
        "req_per_s": int(re.search(r"^Throughput: (\d+) req/s", text, re.M).group(1)),
    }


def peak(token, instance_id, metric, extra_filter, aligner, start, end):
    flt = f'metric.type = "{metric}" AND resource.labels.instance_id = "{instance_id}"'
    if extra_filter:
        flt += f" AND {extra_filter}"
    params = urllib.parse.urlencode({
        "filter": flt,
        "interval.startTime": start.isoformat().replace("+00:00", "Z"),
        # samples are stamped at the end of each minute, so include the one
        # that covers the last part of the run
        "interval.endTime": (end + datetime.timedelta(seconds=60)).isoformat().replace("+00:00", "Z"),
        "aggregation.alignmentPeriod": "60s",
        "aggregation.perSeriesAligner": aligner,
    })
    url = f"https://monitoring.googleapis.com/v3/projects/{PROJECT_ID}/timeSeries?{params}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    data = json.load(urllib.request.urlopen(req))
    values = [
        float(p["value"].get("doubleValue", p["value"].get("int64Value", 0)))
        for series in data.get("timeSeries", [])
        for p in series["points"]
    ]
    return max(values) if values else None


def main():
    results_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results")
    runs = sorted(
        (parse_summary(os.path.join(results_dir, d, "summary.txt"))
         for d in os.listdir(results_dir)
         if os.path.isfile(os.path.join(results_dir, d, "summary.txt"))),
        key=lambda r: r["start"],
    )
    if not runs:
        sys.exit(f"no summary.txt files found under {results_dir}")

    token = gcloud("auth", "print-access-token")
    instance_id = gcloud("compute", "instances", "describe", VM, "--zone", ZONE,
                         "--project", PROJECT_ID, "--format", "value(id)")

    for run in runs:
        for key, (metric, extra, aligner, scale) in METRICS.items():
            value = peak(token, instance_id, metric, extra, aligner, run["start"], run["end"])
            run[key] = None if value is None else round(value * scale, 2)

    fmt = lambda v: "n/a" if v is None else v
    print(f"{'clients':>7} {'start (UTC)':>19} {'secs':>5} {'req/s':>5} {'errors':>6} "
          f"{'CPU %':>6} {'Mem %':>6} {'Sent MiB/s':>10} {'Recv MiB/s':>10}")
    for r in runs:
        print(f"{r['clients']:>7} {r['start']:%Y-%m-%d %H:%M:%S} {r['elapsed_s']:>5} "
              f"{r['req_per_s']:>5} {r['errors']:>6} {fmt(r['cpu_pct']):>6} "
              f"{fmt(r['mem_pct']):>6} {fmt(r['sent_mibps']):>10} {fmt(r['recv_mibps']):>10}")

    # graph uses the most recent run of each concurrency level
    latest = {r["clients"]: r for r in runs}
    fields = ["clients", "req_per_s", "errors", "elapsed_s",
              "cpu_pct", "mem_pct", "sent_mibps", "recv_mibps"]
    os.makedirs(os.path.dirname(CSV_PATH), exist_ok=True)
    with open(CSV_PATH, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for n in sorted(latest):
            writer.writerow(latest[n])
    print(f"\nWrote {os.path.normpath(CSV_PATH)} (latest run per client count)")


if __name__ == "__main__":
    main()
