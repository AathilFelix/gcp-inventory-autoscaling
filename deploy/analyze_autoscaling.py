#!/usr/bin/env python3
"""Pull per-instance CPU utilisation from Cloud Monitoring and plot how the autoscaler reacted.

usage: analyze_autoscaling.py <start-iso> <end-iso> <load-start-iso> <load-end-iso> <out-dir>

Writes <out-dir>/autoscaling.png and <out-dir>/autoscaling.csv. Everything plotted comes from the
Monitoring API (compute.googleapis.com/instance/cpu/utilization), nothing is simulated.
"""
import csv
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt

PROJECT = "inventory-gce-24cs010"
TARGET = 0.60


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def token():
    return subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()


def fetch(start, end):
    params = {
        "filter": 'metric.type="compute.googleapis.com/instance/cpu/utilization" '
                  'AND metadata.system_labels.instance_group="inventory-mig"',
        "interval.startTime": start,
        "interval.endTime": end,
        "aggregation.alignmentPeriod": "60s",
        "aggregation.perSeriesAligner": "ALIGN_MEAN",
    }
    series, page = [], None
    while True:
        if page:
            params["pageToken"] = page
        url = f"https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
        body = json.load(urllib.request.urlopen(req))
        series += body.get("timeSeries", [])
        page = body.get("nextPageToken")
        if not page:
            return series


def group_size_events(start, end):
    """Group size over time from the Cloud Logging audit log (instance insert = +1, delete = -1)."""
    out = subprocess.check_output([
        "gcloud", f"--project={PROJECT}", "logging", "read",
        'resource.type="gce_instance" AND protoPayload.methodName=~"v1.compute.instances.(insert|delete)" '
        f'AND operation.first=true AND timestamp>="{start}" AND timestamp<="{end}"',
        "--format=json", "--order=asc"], text=True)
    size, points = 0, []
    for e in json.loads(out):
        size += 1 if e["protoPayload"]["methodName"].endswith("insert") else -1
        points.append((parse(e["timestamp"]), size))
    return points


def main():
    start, end, load_start, load_end, out = sys.argv[1:6]
    series = fetch(start, end)
    per_minute = defaultdict(dict)  # minute -> {instance: cpu}
    for s in series:
        name = s["metric"]["labels"].get("instance_name") or s["resource"]["labels"].get("instance_id")
        for p in s["points"]:
            t = parse(p["interval"]["endTime"]).replace(second=0, microsecond=0)
            per_minute[t][name] = p["value"]["doubleValue"]

    minutes = sorted(per_minute)
    rows = [(t, len(per_minute[t]), sum(per_minute[t].values()) / len(per_minute[t]) * 100) for t in minutes]
    with open(f"{out}/autoscaling.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["minute_utc", "instances_reporting", "avg_cpu_percent"])
        for t, n, c in rows:
            w.writerow([t.strftime("%Y-%m-%dT%H:%M:%SZ"), n, f"{c:.1f}"])

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(9, 6), sharex=True, gridspec_kw={"height_ratios": [1, 1.2]})
    xs = [r[0] for r in rows]
    events = group_size_events(start, end)
    ev_x = [e[0] for e in events] + [parse(end)]
    ev_y = [e[1] for e in events] + [events[-1][1]]
    ax1.step(ev_x, ev_y, where="post", color="#1a73e8", linewidth=2.2, label="Group size (audit log)")
    ax1.step(xs, [r[1] for r in rows], where="post", color="#9aa0a6", linewidth=1.2, linestyle="--",
             label="Instances reporting CPU metrics")
    ax1.legend(loc="lower right", frameon=False, fontsize=8)
    ax1.set_ylabel("Instances")
    ax1.set_yticks(range(0, 6))
    ax1.set_ylim(0, 5)
    ax2.plot(xs, [r[2] for r in rows], color="#d93025", linewidth=2, marker="o", markersize=3, label="Average CPU across group")
    ax2.axhline(TARGET * 100, color="#188038", linestyle="--", label="Autoscaler target (60%)")
    ax2.set_ylabel("CPU utilisation (% of baseline)")
    ax2.set_ylim(0, max(105, max(r[2] for r in rows) * 1.12))  # shared-core VMs can report more than 100%
    ax2.legend(loc="upper right", frameon=False)
    for ax in (ax1, ax2):
        ax.axvspan(parse(load_start), parse(load_end), color="#fbbc04", alpha=0.18)
        ax.grid(alpha=0.25)
    ax1.text(parse(load_start), 4.55, " load test", fontsize=9, color="#7a5c00")
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=timezone.utc))
    ax2.set_xlabel("Time (UTC)")
    fig.tight_layout()
    fig.savefig(f"{out}/autoscaling.png", dpi=200)
    print(f"{len(rows)} minutes, peak instances={max(e[1] for e in events)}, peak avg CPU={max(r[2] for r in rows):.1f}%")


if __name__ == "__main__":
    main()
