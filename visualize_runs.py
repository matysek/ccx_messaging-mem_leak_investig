#!/usr/bin/env python3
"""Visualize monitoring CSV data from two runs side by side."""

import csv
import os
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime

BASE = "/var/home/mzibrick/Projects/RH-ccx/CCXDEV-15098-mem_leak_investig"
RUNS = [
    ("local_monitoring_20260401_100404", "Run 1 (10:04)"),
    ("local_monitoring_20260401_114149", "Run 2 (11:41)"),
]
CONTAINERS = ["rules-processing", "archive-sync", "rules-uploader"]


def read_csv(path):
    with open(path) as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    return rows


def parse_mem_mb(val):
    """Parse memory string like '62.64MB' or '1.234GB'."""
    val = val.strip()
    if val.endswith("GB"):
        return float(val[:-2]) * 1024
    elif val.endswith("MB"):
        return float(val[:-2])
    elif val.endswith("kB"):
        return float(val[:-2]) / 1024
    return float(val)


def plot_all():
    fig, axes = plt.subplots(3, 2, figsize=(18, 14), sharex="col")
    fig.suptitle("CCX Memory Monitoring — Apr 1 Runs", fontsize=16, fontweight="bold")

    for col, (run_dir, run_label) in enumerate(RUNS):
        run_path = os.path.join(BASE, run_dir)

        for row, container in enumerate(CONTAINERS):
            ax = axes[row, col]

            # --- Podman stats (container-level memory) ---
            podman_csv = os.path.join(run_path, f"{container}_podman_stats.csv")
            podman = read_csv(podman_csv)
            elapsed = [float(r["elapsed_min"]) for r in podman]
            mem_mb = [parse_mem_mb(r["mem_usage_mb"]) for r in podman]
            ax.plot(elapsed, mem_mb, label="podman stats (container)", color="tab:blue", linewidth=1)

            # --- Process memory from /proc/1/status ---
            proc_csv = os.path.join(run_path, f"{container}_process_memory.csv")
            proc = read_csv(proc_csv)
            proc_elapsed = [float(r["elapsed_min"]) for r in proc]
            # cgroup_mem_bytes is the most reliable
            cgroup_mb = [float(r.get("cgroup_mem_bytes") or 0) / (1024 * 1024) for r in proc]
            ax.plot(proc_elapsed, cgroup_mb, label="cgroup memory", color="tab:orange", linewidth=1, alpha=0.8)

            # --- Prometheus process_rss_bytes ---
            prom_csv = os.path.join(run_path, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            prom_elapsed = [float(r["elapsed_min"]) for r in prom]
            prom_rss = [float(r["process_rss_bytes"]) / (1024 * 1024) for r in prom]
            ax.plot(prom_elapsed, prom_rss, label="process RSS (prom)", color="tab:green", linewidth=1, alpha=0.8)

            # Annotate start/end
            if mem_mb:
                ax.annotate(f"{mem_mb[0]:.1f}", xy=(elapsed[0], mem_mb[0]), fontsize=8, color="tab:blue")
                ax.annotate(f"{mem_mb[-1]:.1f}", xy=(elapsed[-1], mem_mb[-1]), fontsize=8, color="tab:blue")

            ax.set_ylabel("Memory (MB)")
            ax.set_title(f"{container} — {run_label}")
            ax.grid(True, alpha=0.3)
            if row == 0:
                ax.legend(loc="upper left", fontsize=8)
            if row == 2:
                ax.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out = os.path.join(BASE, "apr1_memory_comparison.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")

    # --- Prometheus detail plots (broker dicts, GC, pipeline counters) ---
    fig2, axes2 = plt.subplots(3, 2, figsize=(18, 14), sharex="col")
    fig2.suptitle("CCX Prometheus Metrics — Apr 1 Runs", fontsize=16, fontweight="bold")

    for col, (run_dir, run_label) in enumerate(RUNS):
        run_path = os.path.join(BASE, run_dir)

        for row, container in enumerate(CONTAINERS):
            ax = axes2[row, col]
            prom_csv = os.path.join(run_path, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            elapsed = [float(r["elapsed_min"]) for r in prom]

            # Broker dict sizes
            broker_inst = [float(r.get("broker_instances", 0)) for r in prom]
            broker_exc = [float(r.get("broker_exceptions", 0)) for r in prom]
            broker_tb = [float(r.get("broker_tracebacks", 0)) for r in prom]

            ax.plot(elapsed, broker_inst, label="broker_instances", color="tab:blue", linewidth=1)
            ax.plot(elapsed, broker_exc, label="broker_exceptions", color="tab:red", linewidth=1)
            ax.plot(elapsed, broker_tb, label="broker_tracebacks", color="tab:orange", linewidth=1)

            # Pipeline counters on secondary axis
            ax2 = ax.twinx()
            ccx_recv = [float(r.get("ccx_received", 0)) for r in prom]
            ccx_proc = [float(r.get("ccx_processed_ocp", 0)) for r in prom]
            ax2.plot(elapsed, ccx_recv, label="received", color="tab:purple", linewidth=1, linestyle="--", alpha=0.7)
            ax2.plot(elapsed, ccx_proc, label="processed", color="tab:cyan", linewidth=1, linestyle="--", alpha=0.7)
            ax2.set_ylabel("Pipeline counters", fontsize=8)

            ax.set_ylabel("Broker dict size")
            ax.set_title(f"{container} — {run_label}")
            ax.grid(True, alpha=0.3)
            if row == 0:
                ax.legend(loc="upper left", fontsize=8)
                ax2.legend(loc="upper right", fontsize=8)
            if row == 2:
                ax.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out2 = os.path.join(BASE, "apr1_prometheus_detail.png")
    plt.savefig(out2, dpi=150)
    print(f"Saved: {out2}")

    # --- GC collections plot ---
    fig3, axes3 = plt.subplots(3, 2, figsize=(18, 14), sharex="col")
    fig3.suptitle("CCX GC Stats — Apr 1 Runs", fontsize=16, fontweight="bold")

    for col, (run_dir, run_label) in enumerate(RUNS):
        run_path = os.path.join(BASE, run_dir)

        for row, container in enumerate(CONTAINERS):
            ax = axes3[row, col]
            prom_csv = os.path.join(run_path, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            elapsed = [float(r["elapsed_min"]) for r in prom]

            gc0 = [float(r["gc_collections_gen0"]) for r in prom]
            gc1 = [float(r["gc_collections_gen1"]) for r in prom]
            gc2 = [float(r["gc_collections_gen2"]) for r in prom]

            ax.plot(elapsed, gc0, label="gen0 collections", color="tab:green", linewidth=1)
            ax.plot(elapsed, gc1, label="gen1 collections", color="tab:orange", linewidth=1)
            ax.plot(elapsed, gc2, label="gen2 collections", color="tab:red", linewidth=1)

            # Overlay RSS on secondary axis for correlation
            ax2 = ax.twinx()
            prom_rss = [float(r["process_rss_bytes"]) / (1024 * 1024) for r in prom]
            ax2.plot(elapsed, prom_rss, label="RSS (MB)", color="tab:blue", linewidth=1, alpha=0.5, linestyle=":")
            ax2.set_ylabel("RSS (MB)", fontsize=8)

            ax.set_ylabel("GC collections (cumulative)")
            ax.set_title(f"{container} — {run_label}")
            ax.grid(True, alpha=0.3)
            if row == 0:
                ax.legend(loc="upper left", fontsize=8)
                ax2.legend(loc="upper right", fontsize=8)
            if row == 2:
                ax.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out3 = os.path.join(BASE, "apr1_gc_stats.png")
    plt.savefig(out3, dpi=150)
    print(f"Saved: {out3}")


if __name__ == "__main__":
    plot_all()
