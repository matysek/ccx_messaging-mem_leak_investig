# CCXDEV-15098: CCX Memory Leak Investigation

## Status: FIXED and VERIFIED

Memory leak in CCX messaging services has been identified, fixed, and verified.

## Summary

All CCX messaging containers (rules-processing, archive-sync, rules-uploader) exhibited steady memory growth of ~1-9 MB/hr in production. Two root causes were identified and fixed:

1. **Circular references in Broker exception handling** (per-archive): `Broker -> exceptions -> exception -> __traceback__ -> frame -> Broker` prevented GC from collecting Broker objects after each archive
2. **Kafka stats callback label cardinality** (time-based, every 10s): `state` label on `KAFKA_CONSUMER_REBALANCE_COUNT` gauge created unbounded child metrics in prometheus_client

## Fix Verification Results

### Pre-Fix vs Post-Fix Comparison

| Container | Pre-Fix (Dec 14 baseline) | Post-Fix (Mar 30, 12hr) | Status |
|---|---|---|---|
| **rules-processing** | +8.80 MB/hr (linear growth) | 0 MB/hr (sawtooth GC) | FIXED |
| **archive-sync** | +4.88 MB/hr (median) | -1.30 MB/hr (decreasing) | FIXED |
| **rules-uploader** | stable | stable | Not affected |

Post-fix rules-processing peaked at 198 MB at 8.7h, then GC reclaimed memory dropping to 132 MB -- healthy Python GC sawtooth behavior, not linear leak.

All containers show `broker_exceptions=0`, `broker_tracebacks=0` throughout 12hr run (broker cleanup working).

## Upstream PRs (draft)

| Repo | PR | What |
|---|---|---|
| RedHatInsights/insights-core-messaging | #74 | Broker cleanup in Consumer.process() + Kafka metrics label fix |
| RedHatInsights/insights-core | #4763 | `ex.__traceback__ = None` in dr.py run() |
| RedHatInsights/insights-ccx-messaging | #671 | Broker size Prometheus gauges + test fix |

Branch: `mzibrick-ccxdev15098-memleak` in all repos.

## Root Cause Details

### Leak 1: Broker circular references

In `insights/core/dr.py`, the `run()` function catches exceptions and stores them in `broker.exceptions[component]` with `broker.tracebacks[ex] = traceback.format_exc()`. The exception's `__traceback__` attribute holds a reference to the stack frame, which references local variables including `broker`, creating a circular reference chain. Since the broker dicts keep these objects reachable, GC sees them as "in use" and never collects them.

**Fix**: Clear `ex.__traceback__` after storing the formatted string, and clean up broker dicts in `Consumer.process()` finally block.

### Leak 2: Kafka metrics label cardinality

In `insights_messaging/consumers/kafka.py`, the `KafkaMetrics.stats_to_metrics()` callback fires every 10s via confluent-kafka. The `state` label value changes over time (`"up"`, `"rebalancing"`, etc.), and each unique label combination creates a new child metric stored permanently in prometheus_client's internal `_metrics` dict.

**Fix**: Remove `state` from `KAFKA_CONSUMER_REBALANCE_COUNT` labelnames.

## Files in This Repository

### Scripts

All scripts use `podman` (not docker). Updated 2026-03-30.

| Script | Purpose |
|---|---|
| `send_archives.py` | Archive upload with continuous/burst modes |
| `monitor_all_local.sh` | Main monitoring: podman stats + /proc/1/status + Prometheus + logs + auto-summary |
| `monitor_local.sh` | Single container variant (takes container name arg) |
| `collect_internal_metrics_all.sh` | Internal metrics for all containers via Prometheus |
| `collect_internal_metrics.sh` | Single container variant |
| `collect_broker_internals.sh` | Detailed memory via /proc/1/smaps_rollup + Prometheus |

### Patch Files

Apply with `git apply -p0 <file>.patch` from the respective repo root.

| File | Repo | Contents |
|---|---|---|
| `insights-core-messaging.patch` | insights-core-messaging | Broker cleanup + Kafka metrics fix |
| `insights-core.patch` | insights-core | `ex.__traceback__ = None` in dr.py |
| `ccx-messaging.patch` | ccx-messaging | Broker size gauges + test fix |

### Analysis Reports

| File | Contents |
|---|---|
| `memory_leak_comparison_report.txt` | Full pre-fix (Dec 2025) vs post-fix (Mar 2026) comparison |
| `COMPARISON_SUMMARY.md` | Side-by-side tables comparing Mar 26 (unfixed) vs Mar 30 (fixed) |
| `MEMLEAK-FIX_ANALYSIS.md` | Analysis notes |
| `leak_comparison_report_20260330.txt` | Numerical comparison report |
| `final_leak_report_20260330.txt` | Comprehensive analysis with interpretation |
| `QUICK_REFERENCE.txt` | Quick lookup card with key numbers |

### Monitoring Data Directories

| Directory | Date | Duration | Description |
|---|---|---|---|
| `pre_fix_verified_leak/` | Dec 2025 - Jan 2026 | 2-4 hours | **Baseline**: unfixed production image, confirmed leak (+8.8 MB/hr) |
| `pre_fix_smaller/` | Earlier | Various | Earlier pre-fix runs |
| `monitored_still_leaky/` | Earlier | Various | Extra monitoring (more logging), still leaky |
| `dr_py_still_leaky/` | Earlier | Various | dr.py-only partial fix, still leaky |
| `unsure/` | Earlier | Various | Inconclusive runs |
| `local_monitoring_20260325_073850/` | 2026-03-25 | 4 hours | Discovered docker exec GC bug, PermissionError storm |
| `local_monitoring_20260326_073712/` | 2026-03-26 | 9.2 hours | Confirmed leak is time-based (~1 MB/hr), zero errors |
| `local_monitoring_20260330_165910/` | 2026-03-30 | Failed | First podman attempt, headers only |
| `local_monitoring_20260330_171224/` | 2026-03-30 | **12 hours** | **Post-fix verification**: leak eliminated, memory stable/decreasing |

## Containers Monitored

| Container | Prometheus Port | Role |
|---|---|---|
| rules-processing | 8001 | Runs OCP rules against archives (~500 components) |
| archive-sync | 8000 | Syncs archives from S3 |
| rules-uploader | 8000 | Uploads rule results |

## Investigation Timeline

| Date | Milestone |
|---|---|
| 2025-12-12 | First monitoring runs, leak observed |
| 2025-12-14 | Critical baseline established: +8.8 MB/hr in rules-processing |
| 2026-03-24 | Cleaned up scripts, removed archive-sync-ols and multiplexor |
| 2026-03-25 | Discovered docker exec python3 GC bug, fixed PermissionError |
| 2026-03-26 | Rewrote all monitoring scripts with Prometheus + /proc/1/status |
| 2026-03-27 | 9.2hr run confirmed leak is time-based, identified two root causes |
| 2026-03-30 | Applied fixes, created PRs, switched to podman, added broker gauges |
| 2026-03-31 | 12hr post-fix run verified leak is eliminated |

## Testing Methodology

### Local Testing Setup

1. **Start local environment** (local deploy repo):
   ```bash
   podman compose up -d
   ```

2. **Setup archive sending script:**
   ```bash
   python3 -m venv venv
   source venv/bin/activate

   PIP_INDEX_URL=https://pypi.org/simple \
   PIP_EXTRA_INDEX_URL=https://repository.engineering.redhat.com/nexus/repository/insights-qe/simple \
   pip install git+https://gitlab.cee.redhat.com/ccx/molodec.git@master

   pip install click requests
   ```

3. **Run monitoring:**
   ```bash
   # Main monitoring (default 12 hours)
   ./monitor_all_local.sh

   # Custom duration and output dir
   ./monitor_all_local.sh 1440 my_24hr_run
   ```

4. **Send test archives:**
   ```bash
   # Continuous (4 hours)
   python send_archives.py upload

   # Burst mode (send/pause cycles)
   python send_archives.py upload --breaks
   ```

### Important: Why `podman exec python3` Doesn't Work for GC/Broker Stats

`podman exec <container> python3 -c "import gc; ..."` spawns a NEW Python interpreter that doesn't share memory with the application. GC counts returned (42,8,0) were from the fresh process, not the app.

The scripts instead query:
1. **Prometheus `/metrics` endpoint** on the app's HTTP port -- real GC data from the running process
2. **`/proc/1/status`** -- kernel-level memory stats for the actual application PID
3. **`/sys/fs/cgroup/memory.current`** -- container-level memory usage

### Prometheus Metrics Collected

Standard Python/process metrics plus CCX pipeline counters, and (post-fix) broker dict size gauges:
- `ccx_broker_instances_size` -- entries in broker.instances dict
- `ccx_broker_exceptions_size` -- entries in broker.exceptions dict (should be 0 after fix)
- `ccx_broker_tracebacks_size` -- entries in broker.tracebacks dict (should be 0 after fix)
