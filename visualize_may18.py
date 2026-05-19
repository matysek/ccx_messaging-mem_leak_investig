#!/usr/bin/env python3
"""Compare May 18 load test run vs Apr 1 fixed run: full dashboard."""

import csv
import os
import matplotlib.pyplot as plt
import numpy as np

BASE = "/var/home/mzibrick/Projects/RH-ccx/CCXDEV-15098-mem_leak_investig"
RUNS = [
    (os.path.join(BASE, "local_monitoring_20260518_151940"), "May 18"),
    (os.path.join(BASE, "local_monitoring_20260401_145230_FIXED"), "Apr 1 Fixed"),
]
CONTAINERS = ["rules-processing", "archive-sync", "rules-uploader"]
COLORS = ["tab:green", "tab:blue"]


def read_csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def parse_mem_mb(val):
    val = val.strip()
    if val.endswith("GB"):
        return float(val[:-2]) * 1024
    elif val.endswith("MB"):
        return float(val[:-2])
    elif val.endswith("kB"):
        return float(val[:-2]) / 1024
    return float(val)


def plot_memory_cpu():
    """Memory & CPU per container, both runs overlaid."""
    fig, axes = plt.subplots(3, 2, figsize=(16, 12))
    fig.suptitle(
        "May 18 vs Apr 1 Fixed — Memory & CPU per Service",
        fontsize=15, fontweight="bold",
    )

    for row, container in enumerate(CONTAINERS):
        ax_mem = axes[row, 0]
        ax_cpu = axes[row, 1]

        for i, (run_dir, run_label) in enumerate(RUNS):
            color = COLORS[i]
            stats_csv = os.path.join(run_dir, f"{container}_podman_stats.csv")
            data = read_csv(stats_csv)
            if not data:
                continue
            elapsed = [float(r["elapsed_min"]) for r in data]
            mem_mb = [parse_mem_mb(r["mem_usage_mb"]) for r in data]
            cpu = [float(r["cpu_perc"]) for r in data]

            ax_mem.plot(elapsed, mem_mb, label=run_label, color=color, linewidth=1.2)

            if len(elapsed) > 10:
                z = np.polyfit(elapsed, mem_mb, 1)
                trend = np.poly1d(z)
                ax_mem.plot(elapsed, trend(elapsed), color=color, linewidth=1,
                            linestyle="--", alpha=0.6)
                rate = z[0] * 60
                ax_mem.annotate(
                    f"{run_label}: {rate:+.2f} MB/hr",
                    xy=(0.02, 0.95 - (0.08 * i)),
                    xycoords="axes fraction", fontsize=9, color=color,
                    fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8),
                )

            ax_mem.annotate(f"{mem_mb[0]:.1f}", xy=(elapsed[0], mem_mb[0]),
                            fontsize=7, color=color, textcoords="offset points",
                            xytext=(5, 5))
            ax_mem.annotate(f"{mem_mb[-1]:.1f}", xy=(elapsed[-1], mem_mb[-1]),
                            fontsize=7, color=color, textcoords="offset points",
                            xytext=(5, -10))

            window = 12
            if len(cpu) > window:
                cpu_smooth = np.convolve(cpu, np.ones(window) / window, mode="valid")
                elapsed_smooth = elapsed[window - 1:]
                ax_cpu.plot(elapsed_smooth, cpu_smooth, label=f"{run_label} (2min avg)",
                            color=color, linewidth=1.2)
            else:
                ax_cpu.plot(elapsed, cpu, label=run_label, color=color, linewidth=1.2)

            avg_cpu = np.mean(cpu)
            ax_cpu.axhline(y=avg_cpu, color=color, linewidth=0.8, linestyle=":", alpha=0.5)
            ax_cpu.annotate(
                f"{run_label} avg: {avg_cpu:.1f}%",
                xy=(0.02, 0.95 - (0.10 * i)),
                xycoords="axes fraction", fontsize=9, color=color,
                fontweight="bold",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8),
            )

        ax_mem.set_ylabel("Memory (MB)")
        ax_mem.set_title(f"{container} — Memory", fontsize=11, fontweight="bold")
        ax_mem.legend(loc="lower left", fontsize=8)
        ax_mem.grid(True, alpha=0.3)

        ax_cpu.set_ylabel("CPU %")
        ax_cpu.set_title(f"{container} — CPU", fontsize=11, fontweight="bold")
        ax_cpu.legend(loc="lower left", fontsize=8)
        ax_cpu.grid(True, alpha=0.3)

        if row == 2:
            ax_mem.set_xlabel("Elapsed (minutes)")
            ax_cpu.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out = os.path.join(BASE, "may18_memory_cpu.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    plt.close()


def plot_rss_broker():
    """Process RSS & Broker Dict sizes, both runs overlaid."""
    fig, axes = plt.subplots(3, 2, figsize=(16, 12))
    fig.suptitle(
        "May 18 vs Apr 1 Fixed — Process RSS & Broker Dicts",
        fontsize=15, fontweight="bold",
    )

    for row, container in enumerate(CONTAINERS):
        ax_rss = axes[row, 0]
        ax_broker = axes[row, 1]

        for i, (run_dir, run_label) in enumerate(RUNS):
            color = COLORS[i]
            prom_csv = os.path.join(run_dir, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            if not prom:
                continue
            elapsed = [float(r["elapsed_min"]) for r in prom]

            rss_mb = [float(r["process_rss_bytes"]) / (1024 * 1024) for r in prom]
            ax_rss.plot(elapsed, rss_mb, label=run_label, color=color, linewidth=1.2)

            if len(elapsed) > 10:
                z = np.polyfit(elapsed, rss_mb, 1)
                rate = z[0] * 60
                ax_rss.annotate(
                    f"{run_label}: {rate:+.2f} MB/hr",
                    xy=(0.02, 0.95 - (0.08 * i)),
                    xycoords="axes fraction", fontsize=9, color=color,
                    fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8),
                )

            broker_inst = [float(r.get("broker_instances", 0)) for r in prom]
            broker_exc = [float(r.get("broker_exceptions", 0)) for r in prom]
            broker_tb = [float(r.get("broker_tracebacks", 0)) for r in prom]

            ax_broker.plot(elapsed, broker_inst, label=f"{run_label} instances",
                           color=color, linewidth=1.2, linestyle="-")
            ax_broker.plot(elapsed, broker_exc, label=f"{run_label} exceptions",
                           color=color, linewidth=1.2, linestyle="--")
            ax_broker.plot(elapsed, broker_tb, label=f"{run_label} tracebacks",
                           color=color, linewidth=1.2, linestyle=":")

        ax_rss.set_ylabel("RSS (MB)")
        ax_rss.set_title(f"{container} — Process RSS", fontsize=11, fontweight="bold")
        ax_rss.legend(loc="upper left", fontsize=8)
        ax_rss.grid(True, alpha=0.3)

        ax_broker.set_ylabel("Dict entries")
        ax_broker.set_title(f"{container} — Broker Dict Sizes", fontsize=11, fontweight="bold")
        ax_broker.legend(loc="upper left", fontsize=7)
        ax_broker.grid(True, alpha=0.3)

        if row == 2:
            ax_rss.set_xlabel("Elapsed (minutes)")
            ax_broker.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out = os.path.join(BASE, "may18_rss_broker.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    plt.close()


def plot_memory_detail():
    """Multi-source memory view, side-by-side layout."""
    fig, axes = plt.subplots(3, 2, figsize=(18, 14), sharex="col")
    fig.suptitle("CCX Memory Monitoring — May 18 vs Apr 1 Fixed", fontsize=16, fontweight="bold")

    for col, (run_dir, run_label) in enumerate(RUNS):
        for row, container in enumerate(CONTAINERS):
            ax = axes[row, col]

            podman_csv = os.path.join(run_dir, f"{container}_podman_stats.csv")
            podman = read_csv(podman_csv)
            if podman:
                elapsed = [float(r["elapsed_min"]) for r in podman]
                mem_mb = [parse_mem_mb(r["mem_usage_mb"]) for r in podman]
                ax.plot(elapsed, mem_mb, label="podman stats", color="tab:blue", linewidth=1)
                if mem_mb:
                    ax.annotate(f"{mem_mb[0]:.1f}", xy=(elapsed[0], mem_mb[0]),
                                fontsize=8, color="tab:blue")
                    ax.annotate(f"{mem_mb[-1]:.1f}", xy=(elapsed[-1], mem_mb[-1]),
                                fontsize=8, color="tab:blue")

            proc_csv = os.path.join(run_dir, f"{container}_process_memory.csv")
            proc = read_csv(proc_csv)
            if proc:
                proc_elapsed = [float(r["elapsed_min"]) for r in proc]
                cgroup_mb = [float(r.get("cgroup_mem_bytes") or 0) / (1024 * 1024) for r in proc]
                if any(v > 0 for v in cgroup_mb):
                    ax.plot(proc_elapsed, cgroup_mb, label="cgroup memory",
                            color="tab:orange", linewidth=1, alpha=0.8)

            prom_csv = os.path.join(run_dir, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            if prom:
                prom_elapsed = [float(r["elapsed_min"]) for r in prom]
                prom_rss = [float(r["process_rss_bytes"]) / (1024 * 1024) for r in prom]
                ax.plot(prom_elapsed, prom_rss, label="process RSS (prom)",
                        color="tab:green", linewidth=1, alpha=0.8)

            ax.set_ylabel("Memory (MB)")
            ax.set_title(f"{container} — {run_label}")
            ax.grid(True, alpha=0.3)
            if row == 0:
                ax.legend(loc="upper left", fontsize=8)
            if row == 2:
                ax.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out = os.path.join(BASE, "may18_memory_detail.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    plt.close()


def plot_prometheus_detail():
    """Broker dicts + pipeline counters, side-by-side layout."""
    fig, axes = plt.subplots(3, 2, figsize=(18, 14), sharex="col")
    fig.suptitle("CCX Prometheus Metrics — May 18 vs Apr 1 Fixed", fontsize=16, fontweight="bold")

    for col, (run_dir, run_label) in enumerate(RUNS):
        for row, container in enumerate(CONTAINERS):
            ax = axes[row, col]
            prom_csv = os.path.join(run_dir, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            if not prom:
                continue
            elapsed = [float(r["elapsed_min"]) for r in prom]

            broker_inst = [float(r.get("broker_instances", 0)) for r in prom]
            broker_exc = [float(r.get("broker_exceptions", 0)) for r in prom]
            broker_tb = [float(r.get("broker_tracebacks", 0)) for r in prom]

            ax.plot(elapsed, broker_inst, label="broker_instances", color="tab:blue", linewidth=1)
            ax.plot(elapsed, broker_exc, label="broker_exceptions", color="tab:red", linewidth=1)
            ax.plot(elapsed, broker_tb, label="broker_tracebacks", color="tab:orange", linewidth=1)

            ax2 = ax.twinx()
            ccx_recv = [float(r.get("ccx_received", 0)) for r in prom]
            ccx_proc = [float(r.get("ccx_processed_ocp", 0)) for r in prom]
            ax2.plot(elapsed, ccx_recv, label="received", color="tab:purple",
                     linewidth=1, linestyle="--", alpha=0.7)
            ax2.plot(elapsed, ccx_proc, label="processed", color="tab:cyan",
                     linewidth=1, linestyle="--", alpha=0.7)
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
    out = os.path.join(BASE, "may18_prometheus_detail.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    plt.close()


def plot_gc_stats():
    """GC collections + RSS overlay, side-by-side layout."""
    fig, axes = plt.subplots(3, 2, figsize=(18, 14), sharex="col")
    fig.suptitle("CCX GC Stats — May 18 vs Apr 1 Fixed", fontsize=16, fontweight="bold")

    for col, (run_dir, run_label) in enumerate(RUNS):
        for row, container in enumerate(CONTAINERS):
            ax = axes[row, col]
            prom_csv = os.path.join(run_dir, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            if not prom:
                continue
            elapsed = [float(r["elapsed_min"]) for r in prom]

            gc0 = [float(r["gc_collections_gen0"]) for r in prom]
            gc1 = [float(r["gc_collections_gen1"]) for r in prom]
            gc2 = [float(r["gc_collections_gen2"]) for r in prom]

            ax.plot(elapsed, gc0, label="gen0 collections", color="tab:green", linewidth=1)
            ax.plot(elapsed, gc1, label="gen1 collections", color="tab:orange", linewidth=1)
            ax.plot(elapsed, gc2, label="gen2 collections", color="tab:red", linewidth=1)

            ax2 = ax.twinx()
            prom_rss = [float(r["process_rss_bytes"]) / (1024 * 1024) for r in prom]
            ax2.plot(elapsed, prom_rss, label="RSS (MB)", color="tab:blue",
                     linewidth=1, alpha=0.5, linestyle=":")
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
    out = os.path.join(BASE, "may18_gc_stats.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")
    plt.close()


if __name__ == "__main__":
    plot_memory_cpu()
    plot_rss_broker()
    plot_memory_detail()
    plot_prometheus_detail()
    plot_gc_stats()
    print("\nDone — all 5 graphs generated.")
