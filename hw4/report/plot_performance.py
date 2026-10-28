"""Performance graph for the HW4 stress test.

Reads metrics.csv (written by stress-test/fetch-metrics.py: peak usage of
hw4-web for each concurrency level) and saves performance.png next to it.

    python3 report/plot_performance.py
"""
import csv
import os

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "metrics.csv")) as f:
    rows = sorted(csv.DictReader(f), key=lambda r: int(r["clients"]))

clients = [int(r["clients"]) for r in rows]
col = lambda name: [float(r[name]) if r[name] else float("nan") for r in rows]

BLUE, ORANGE = "#2a78d6", "#eb6834"
INK, INK2, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, SURFACE = "#e1e0d9", "#c3c2b7", "#fcfcfb"

plt.rcParams.update({"font.size": 10, "text.color": INK, "axes.labelcolor": INK2,
                     "xtick.color": MUTED, "ytick.color": MUTED})
fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(15, 4.6), facecolor=SURFACE)


def style(ax, title, ylabel, ymax):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, loc="left", fontsize=12, fontweight="bold", color=INK, pad=12)
    ax.set_xlabel("Concurrent clients")
    ax.set_ylabel(ylabel)
    ax.set_xticks(clients)
    ax.set_xlim(min(clients) - 0.3, max(clients) + 0.6)
    ax.set_ylim(0, ymax)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(AXIS)
    ax.tick_params(length=0)


def series(ax, y, color, label, fmt, below=False):
    ax.plot(clients, y, color=color, linewidth=2, marker="o", markersize=7,
            markeredgecolor=SURFACE, markeredgewidth=2, label=label, zorder=3)
    for x, v in zip(clients, y):
        ax.annotate(fmt.format(v), (x, v), xytext=(0, -17 if below else 9),
                    textcoords="offset points", ha="center", fontsize=8.5, color=INK2)


style(ax1, "CPU and memory utilization", "Peak utilization (%)",
      max(100, max(col("cpu_pct")) * 1.15))
series(ax1, col("cpu_pct"), BLUE, "CPU", "{:.1f}%")
series(ax1, col("mem_pct"), ORANGE, "Memory", "{:.1f}%", below=True)
ax1.legend(loc="lower right", frameon=False, ncol=2)

net_max = max(col("sent_mibps") + col("recv_mibps"))
style(ax2, "Network bandwidth", "Peak throughput (MiB/s)", net_max * 1.35)
series(ax2, col("sent_mibps"), BLUE, "Sent", "{:.2f}")
series(ax2, col("recv_mibps"), ORANGE, "Received", "{:.2f}", below=True)
ax2.legend(loc="upper left", frameon=False, ncol=2)

style(ax3, "Requests served per second", "Throughput (req/s, all clients)",
      max(col("req_per_s")) * 1.35)
series(ax3, col("req_per_s"), BLUE, "Throughput", "{:.0f}")

fig.suptitle("hw4-web (e2-micro) resource usage vs. concurrent clients",
             x=0.01, ha="left", fontsize=13, fontweight="bold", color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.95))
out = os.path.join(HERE, "performance.png")
fig.savefig(out, dpi=200, facecolor=SURFACE)
print(f"saved {out}")
