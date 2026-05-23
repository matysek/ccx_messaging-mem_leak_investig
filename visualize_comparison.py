#!/usr/bin/env python3
"""Compare fixed vs leaky runs: memory and CPU for each service."""

import csv
import os
import matplotlib.pyplot as plt
import numpy as np

BASE = "/var/home/mzibrick/Projects/RH-ccx/CCXDEV-15098-mem_leak_investig"
FIXED_DIR = os.path.join(BASE, "local_monitoring_20260401_145230")
LEAKY_DIR = os.path.join(BASE, "local_monitoring_20260401_132347")
CONTAINERS = ["rules-processing", "archive-sync", "rules-uploader"]
COLORS = {"fixed": "tab:green", "leaky": "tab:red"}


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


def main():
    fig, axes = plt.subplots(3, 2, figsize=(16, 12))
    fig.suptitle(
        "Fixed vs Leaky — Memory & CPU per Service (Apr 1, 2026)",
        fontsize=15, fontweight="bold"
    )

    for row, container in enumerate(CONTAINERS):
        ax_mem = axes[row, 0]
        ax_cpu = axes[row, 1]

        for label, run_dir, color, ls in [
            ("Fixed", FIXED_DIR, COLORS["fixed"], "-"),
            ("Leaky", LEAKY_DIR, COLORS["leaky"], "-"),
        ]:
            stats_csv = os.path.join(run_dir, f"{container}_podman_stats.csv")
            data = read_csv(stats_csv)
            elapsed = [float(r["elapsed_min"]) for r in data]
            mem_mb = [parse_mem_mb(r["mem_usage_mb"]) for r in data]
            cpu = [float(r["cpu_perc"]) for r in data]

            # Memory plot
            ax_mem.plot(elapsed, mem_mb, label=label, color=color, linewidth=1.2, linestyle=ls)

            # Add trend line
            if len(elapsed) > 10:
                z = np.polyfit(elapsed, mem_mb, 1)
                trend = np.poly1d(z)
                ax_mem.plot(elapsed, trend(elapsed), color=color, linewidth=1,
                           linestyle="--", alpha=0.6)
                rate = z[0] * 60  # MB/hr
                ax_mem.annotate(
                    f"{label}: {rate:+.2f} MB/hr",
                    xy=(0.02, 0.95 - (0.08 if label == "Leaky" else 0)),
                    xycoords="axes fraction", fontsize=9, color=color,
                    fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8)
                )

            # Annotate start/end memory
            ax_mem.annotate(f"{mem_mb[0]:.1f}", xy=(elapsed[0], mem_mb[0]),
                          fontsize=7, color=color, textcoords="offset points",
                          xytext=(5, 5))
            ax_mem.annotate(f"{mem_mb[-1]:.1f}", xy=(elapsed[-1], mem_mb[-1]),
                          fontsize=7, color=color, textcoords="offset points",
                          xytext=(5, -10))

            # CPU plot — use rolling average for readability
            window = 12  # 2 min window at 10s intervals
            if len(cpu) > window:
                cpu_smooth = np.convolve(cpu, np.ones(window)/window, mode="valid")
                elapsed_smooth = elapsed[window-1:]
                ax_cpu.plot(elapsed_smooth, cpu_smooth, label=f"{label} (2min avg)",
                          color=color, linewidth=1.2, linestyle=ls)
            else:
                ax_cpu.plot(elapsed, cpu, label=label, color=color, linewidth=1.2)

            # CPU average annotation
            avg_cpu = np.mean(cpu)
            ax_cpu.axhline(y=avg_cpu, color=color, linewidth=0.8, linestyle=":",
                          alpha=0.5)
            ax_cpu.annotate(
                f"{label} avg: {avg_cpu:.1f}%",
                xy=(0.02, 0.95 - (0.10 if label == "Leaky" else 0)),
                xycoords="axes fraction", fontsize=9, color=color,
                fontweight="bold",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8)
            )

        # Memory axis formatting
        ax_mem.set_ylabel("Memory (MB)", fontsize=10)
        ax_mem.set_title(f"{container} — Memory", fontsize=11, fontweight="bold")
        ax_mem.legend(loc="lower left", fontsize=8)
        ax_mem.grid(True, alpha=0.3)

        # CPU axis formatting
        ax_cpu.set_ylabel("CPU %", fontsize=10)
        ax_cpu.set_title(f"{container} — CPU", fontsize=11, fontweight="bold")
        ax_cpu.legend(loc="lower left", fontsize=8)
        ax_cpu.grid(True, alpha=0.3)

        if row == 2:
            ax_mem.set_xlabel("Elapsed (minutes)")
            ax_cpu.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out = os.path.join(BASE, "apr1_fixed_vs_leaky.png")
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")

    # --- Prometheus RSS + broker dicts comparison ---
    fig2, axes2 = plt.subplots(3, 2, figsize=(16, 12))
    fig2.suptitle(
        "Fixed vs Leaky — Process RSS & Broker Dicts (Apr 1, 2026)",
        fontsize=15, fontweight="bold"
    )

    for row, container in enumerate(CONTAINERS):
        ax_rss = axes2[row, 0]
        ax_broker = axes2[row, 1]

        for label, run_dir, color in [
            ("Fixed", FIXED_DIR, COLORS["fixed"]),
            ("Leaky", LEAKY_DIR, COLORS["leaky"]),
        ]:
            prom_csv = os.path.join(run_dir, f"{container}_prometheus.csv")
            prom = read_csv(prom_csv)
            elapsed = [float(r["elapsed_min"]) for r in prom]

            # RSS from Prometheus
            rss_mb = [float(r["process_rss_bytes"]) / (1024 * 1024) for r in prom]
            ax_rss.plot(elapsed, rss_mb, label=label, color=color, linewidth=1.2)

            # RSS trend
            if len(elapsed) > 10:
                z = np.polyfit(elapsed, rss_mb, 1)
                rate = z[0] * 60
                ax_rss.annotate(
                    f"{label}: {rate:+.2f} MB/hr",
                    xy=(0.02, 0.95 - (0.08 if label == "Leaky" else 0)),
                    xycoords="axes fraction", fontsize=9, color=color,
                    fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8)
                )

            # Broker dict sizes
            broker_inst = [float(r.get("broker_instances", 0)) for r in prom]
            broker_exc = [float(r.get("broker_exceptions", 0)) for r in prom]
            broker_tb = [float(r.get("broker_tracebacks", 0)) for r in prom]

            ax_broker.plot(elapsed, broker_inst, label=f"{label} instances",
                         color=color, linewidth=1.2, linestyle="-")
            ax_broker.plot(elapsed, broker_exc, label=f"{label} exceptions",
                         color=color, linewidth=1.2, linestyle="--")
            ax_broker.plot(elapsed, broker_tb, label=f"{label} tracebacks",
                         color=color, linewidth=1.2, linestyle=":")

        ax_rss.set_ylabel("RSS (MB)", fontsize=10)
        ax_rss.set_title(f"{container} — Process RSS", fontsize=11, fontweight="bold")
        ax_rss.legend(loc="upper left", fontsize=8)
        ax_rss.grid(True, alpha=0.3)

        ax_broker.set_ylabel("Dict entries", fontsize=10)
        ax_broker.set_title(f"{container} — Broker Dict Sizes", fontsize=11, fontweight="bold")
        ax_broker.legend(loc="upper left", fontsize=7)
        ax_broker.grid(True, alpha=0.3)

        if row == 2:
            ax_rss.set_xlabel("Elapsed (minutes)")
            ax_broker.set_xlabel("Elapsed (minutes)")

    plt.tight_layout()
    out2 = os.path.join(BASE, "apr1_rss_broker_comparison.png")
    plt.savefig(out2, dpi=150)
    print(f"Saved: {out2}")


if __name__ == "__main__":
    main()
