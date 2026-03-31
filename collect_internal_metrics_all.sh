#!/bin/bash

# Collect internal metrics from all CCX containers
#
# NOTE: Previous versions used `podman exec python3 -c "import gc; ..."` which
# spawns a NEW Python interpreter. The GC counts (42,8,0) were from the fresh
# process, not the application. Similarly, dr._BROKER_INSTANCES was empty.
#
# This version queries:
#   1. Prometheus /metrics endpoint (real app GC + process stats)
#   2. /proc/1/status (kernel-level memory of the actual app process)
#   3. cgroup memory stats
#
# For broker dict sizes, a custom endpoint must be added to ccx-messaging.
#
# Usage: ./collect_internal_metrics_all.sh [output_dir]

CONTAINERS=("rules-uploader" "archive-sync" "rules-processing")
OUTPUT_DIR="${1:-local_monitoring_internal_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTPUT_DIR"

# Detect stats endpoint port per container
declare -A STATS_PORT
for CONTAINER in "${CONTAINERS[@]}"; do
    if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        continue
    fi
    PORT=$(podman exec "$CONTAINER" python3 -c "
import urllib.request
for port in [8001, 8000, 9090, 8080]:
    try:
        urllib.request.urlopen(f'http://localhost:{port}/metrics', timeout=2)
        print(port)
        break
    except:
        pass
" 2>/dev/null)
    if [ -n "$PORT" ]; then
        STATS_PORT[$CONTAINER]=$PORT
        echo "$CONTAINER: Prometheus on port $PORT"
    fi
done

# Create CSV files
for CONTAINER in "${CONTAINERS[@]}"; do
    echo "timestamp,elapsed_min,vm_rss_kb,vm_data_kb,cgroup_mem_bytes,gc_collected_gen0,gc_collected_gen1,gc_collected_gen2,gc_uncollectable_gen0,gc_uncollectable_gen1,gc_uncollectable_gen2,gc_collections_gen0,gc_collections_gen1,gc_collections_gen2,process_rss_bytes,process_cpu_seconds,open_fds,ccx_received,ccx_processed_ocp,ccx_failures_ocp,ccx_published_ocp,broker_instances,broker_exceptions,broker_tracebacks" \
        > "$OUTPUT_DIR/${CONTAINER}_internal_metrics.csv"
done

START_TIME=$(date +%s)
ITERATION=0

echo ""
echo "Starting internal metrics collection for: ${CONTAINERS[*]}"
echo "Output: $OUTPUT_DIR/"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    for CONTAINER in "${CONTAINERS[@]}"; do
        if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: NOT RUNNING - skipping"
            continue
        fi

        # Process memory from kernel
        PROC_MEM=$(podman exec "$CONTAINER" sh -c '
            vm_rss=$(grep "^VmRSS:" /proc/1/status 2>/dev/null | awk "{print \$2}")
            vm_data=$(grep "^VmData:" /proc/1/status 2>/dev/null | awk "{print \$2}")
            cgroup=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
            echo "${vm_rss:-0},${vm_data:-0},${cgroup}"
        ' 2>/dev/null)

        # Prometheus metrics
        PORT="${STATS_PORT[$CONTAINER]}"
        PROM="0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
        if [ -n "$PORT" ]; then
            PROM=$(podman exec "$CONTAINER" python3 -c "
import urllib.request, re, sys
try:
    data = urllib.request.urlopen('http://localhost:${PORT}/metrics', timeout=5).read().decode()
    def val(name, labels=''):
        pattern = f'^{name}' + ('{' + labels + '}' if labels else '') + r'\s+([\d.e+\-]+)'
        m = re.search(pattern, data, re.MULTILINE)
        return m.group(1) if m else '0'

    fields = [
        val('python_gc_objects_collected_total', 'generation=\"0\"'),
        val('python_gc_objects_collected_total', 'generation=\"1\"'),
        val('python_gc_objects_collected_total', 'generation=\"2\"'),
        val('python_gc_objects_uncollectable_total', 'generation=\"0\"'),
        val('python_gc_objects_uncollectable_total', 'generation=\"1\"'),
        val('python_gc_objects_uncollectable_total', 'generation=\"2\"'),
        val('python_gc_collections_total', 'generation=\"0\"'),
        val('python_gc_collections_total', 'generation=\"1\"'),
        val('python_gc_collections_total', 'generation=\"2\"'),
        val('process_resident_memory_bytes'),
        val('process_cpu_seconds_total'),
        val('process_open_fds'),
        val('ccx_consumer_received_total'),
        val('ccx_engine_processed_total', 'archive=\"ocp\"'),
        val('ccx_failures_total', 'archive=\"ocp\"'),
        val('ccx_published_total', 'archive=\"ocp\"'),
        val('ccx_broker_instances_size'),
        val('ccx_broker_exceptions_size'),
        val('ccx_broker_tracebacks_size'),
    ]
    print(','.join(fields))
except Exception as e:
    print(','.join(['0']*19), file=sys.stderr)
    print(','.join(['0']*19))
" 2>/dev/null)
        fi

        if [ -n "$PROC_MEM" ]; then
            echo "${TIMESTAMP},${ELAPSED_MIN},${PROC_MEM},${PROM}" \
                >> "$OUTPUT_DIR/${CONTAINER}_internal_metrics.csv"
            VM_RSS=$(echo "$PROC_MEM" | cut -d',' -f1)
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: VmRSS=${VM_RSS}KB"
        else
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: Query failed"
        fi
    done

    echo ""
    ITERATION=$((ITERATION + 1))
    sleep 30
done
