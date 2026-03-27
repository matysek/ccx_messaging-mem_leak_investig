# CCX Memory Leak Investigation

## Overview

Investigation of memory leaks in CCX messaging services. Since the leak is present in all ccx-messaging services we need to investigate
what the common utilities, libraries etc are.

## Suspected Root Cause

### Circular References in Exception Handling

Objects reference each other in a cycle that prevents garbage collection:

**The Problem:**
- Python's GC can usually handle circular references
- Exception tracebacks create circular refs that prevent GC
- Specific issue: `Broker → exception → __traceback__ → frame → Broker`

This circular reference chain keeps objects alive indefinitely, causing the memory leak pattern observed in production.

---

## Testing Methodology

### 1. Baseline Testing

Run locally in Podman to:
- Send large volumes of data without ephemeral environment costs
- Benchmark the performance

### 2. Local Testing Setup

#### Prerequisites

**Local Deployment:**

1. **Optional**:
   ```bash
   # Inside ingress clone directory
   docker build . -t ingress:latest
   docker-compose -f development/local-dev-start.yml up
   ```

2. **Start local environment:**
   ```bash
   # Inside local deploy repo
   docker compose up -d
   ```

3. **Setup archive sending script:**
   ```bash
   # Inside the mem leak repo
   python3 -m venv venv
   source venv/bin/activate

   # Install molodec from GitLab (requires dual pip indexes:
   # PyPI for build tools like hatchling, RH internal for iqe-jwt)
   PIP_INDEX_URL=https://pypi.org/simple \
   PIP_EXTRA_INDEX_URL=https://repository.engineering.redhat.com/nexus/repository/insights-qe/simple \
   pip install git+https://gitlab.cee.redhat.com/ccx/molodec.git@master

   # Install remaining dependencies
   pip install click requests
   ```
---

## Running Tests

### Monitoring Memory Usage

**Main monitoring script (recommended):**

```bash
# Default: 12 hours, auto-named output directory
./monitor_all_local.sh

# Custom duration (24 hours) and output dir
./monitor_all_local.sh 1440 my_test_run
```

This monitors all 3 containers every 10 seconds, capturing:
- **Docker stats** - CPU, memory, network I/O
- **Process memory** - VmRSS, VmData from `/proc/1/status` (actual app process)
- **Cgroup memory** - Container-level memory from cgroup v2
- **Prometheus metrics** - Real GC stats, process RSS, CPU, open FDs, pipeline counters
  - Auto-detects Prometheus port per container (8000 or 8001)
- **Incremental logs** - Only new log lines captured every 10 minutes (not full dumps)
- **Auto-summary** - Generated at end with memory deltas, GC stats, pipeline counters

**Additional monitoring scripts:**

```bash
# Single container monitoring
./monitor_local.sh rules-processing

# Detailed internal metrics (process memory + Prometheus)
./collect_internal_metrics_all.sh
./collect_internal_metrics.sh rules-processing

# Focused broker/GC tracking with /proc/1/smaps_rollup
./collect_broker_internals.sh
```

### Important: Why `docker exec python3` Doesn't Work for GC/Broker Stats

Previous script versions used `docker exec <container> python3 -c "import gc; ..."` to collect
GC and broker data. **This is fundamentally broken** because `docker exec` spawns a NEW Python
interpreter that doesn't share memory with the application. The GC counts returned (42,8,0) were
from the fresh process, not the app. Similarly, `dr._BROKER_INSTANCES` was empty because the
WeakSet only exists in the app's memory space.

The updated scripts query:
1. **Prometheus `/metrics` endpoint** on the app's HTTP port — real GC data from the running process
2. **`/proc/1/status`** — kernel-level memory stats for the actual application PID
3. **`/sys/fs/cgroup/memory.current`** — container-level memory usage

For **broker dict sizes** (instances/exceptions/tracebacks counts), a custom Prometheus gauge
must be added to `ccx_messaging/watchers/stats_watcher.py` to expose these from inside the app.

### Sending Test Archives

1. **Continuous local sending (4 hours):**
```bash
python send_archives.py upload
```

2. **Burst mode (send/pause cycles):**
```bash
python send_archives.py upload --breaks
```

## Containers Monitored

1. **rules-uploader** (Prometheus on port 8000)
2. **archive-sync** (Prometheus on port 8000)
3. **rules-processing** (Prometheus on port 8001)

## Files in This Repository

- `send_archives.py` - Archive upload script with continuous/burst modes
- `monitor_all_local.sh` - Main monitoring script (docker stats + process memory + Prometheus + logs)
- `monitor_local.sh` - Single container variant
- `collect_internal_metrics_all.sh` - Focused internal metrics for all containers
- `collect_internal_metrics.sh` - Focused internal metrics for single container
- `collect_broker_internals.sh` - Detailed memory breakdown with /proc/1/smaps_rollup
- directories with results of the monitoring as explained below

### 3. Results
- **baseline** - confirmed leak - /pre_fix_verified_leak
- **extra monitoring** (more logging, monitoring brokers) - still leaky /monitored_still_leaky
- **dr.py fix** - suspected circular references, containers run with a patch, possibly promising results, but needs more testing - /dr_py_still_leaky

Results are visualised in their directories
