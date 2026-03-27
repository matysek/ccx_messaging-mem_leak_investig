#!/bin/bash

# Monitor BROKER INTERNALS via the application's own process
#
# IMPORTANT: `docker exec python3 -c "from insights.core import dr; ..."` does NOT work
# because it spawns a NEW Python interpreter that doesn't share memory with the app.
# The dr._BROKER_INSTANCES WeakSet will be empty in a fresh process.
#
# This script uses two approaches that DO work:
#   1. /proc/1/smaps_rollup - kernel-level memory breakdown of the app process
#   2. Prometheus /metrics endpoint - real GC data from the running app
#
# For actual broker dict sizes (instances/exceptions/tracebacks), you need to add
# a custom Prometheus gauge to ccx-messaging that exposes these from inside the app.
# See: ccx_messaging/watchers/stats_watcher.py
#
# Usage: ./collect_broker_internals.sh [output_dir]

CONTAINERS=("rules-uploader" "archive-sync" "rules-processing")
OUTPUT_DIR="${1:-local_monitoring_internal_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTPUT_DIR"

# Detect stats endpoint port per container
declare -A STATS_PORT
for CONTAINER in "${CONTAINERS[@]}"; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        continue
    fi
    PORT=$(docker exec "$CONTAINER" python3 -c "
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
    else
        echo "$CONTAINER: No Prometheus endpoint"
    fi
done

# Create CSV files for each container
for CONTAINER in "${CONTAINERS[@]}"; do
    echo "timestamp,elapsed_min,vm_rss_kb,vm_data_kb,anon_huge_kb,rss_anon_kb,rss_file_kb,pss_kb,referenced_kb,gc_collected_total,gc_uncollectable_total,gc_collections_total,open_fds,process_rss_prom" \
        > "$OUTPUT_DIR/${CONTAINER}_broker_internals.csv"
done

START_TIME=$(date +%s)

echo ""
echo "Starting broker internals monitoring for: ${CONTAINERS[*]}"
echo "Output: $OUTPUT_DIR/"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    for CONTAINER in "${CONTAINERS[@]}"; do
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: NOT RUNNING"
            continue
        fi

        # 1. Kernel-level memory from /proc/1/status and /proc/1/smaps_rollup
        #    This is the REAL memory of the running application process
        PROC_DATA=$(docker exec "$CONTAINER" sh -c '
            vm_rss=$(grep "^VmRSS:" /proc/1/status 2>/dev/null | awk "{print \$2}")
            vm_data=$(grep "^VmData:" /proc/1/status 2>/dev/null | awk "{print \$2}")
            # smaps_rollup has detailed breakdown
            anon_huge=$(grep "^AnonHugePages:" /proc/1/smaps_rollup 2>/dev/null | awk "{print \$2}")
            rss_anon=$(grep "^Rss:" /proc/1/smaps_rollup 2>/dev/null | awk "{print \$2}")
            rss_file=$(grep "^Referenced:" /proc/1/smaps_rollup 2>/dev/null | awk "{print \$2}")
            pss=$(grep "^Pss:" /proc/1/smaps_rollup 2>/dev/null | awk "{print \$2}")
            referenced=$(grep "^Referenced:" /proc/1/smaps_rollup 2>/dev/null | awk "{print \$2}")
            echo "${vm_rss:-0},${vm_data:-0},${anon_huge:-0},${rss_anon:-0},${rss_file:-0},${pss:-0},${referenced:-0}"
        ' 2>/dev/null)

        # 2. Prometheus metrics from the app's endpoint
        PORT="${STATS_PORT[$CONTAINER]}"
        PROM_DATA="0,0,0,0,0"
        if [ -n "$PORT" ]; then
            PROM_DATA=$(docker exec "$CONTAINER" python3 -c "
import urllib.request, re, sys
try:
    data = urllib.request.urlopen('http://localhost:${PORT}/metrics', timeout=5).read().decode()
    def val(name, labels=''):
        pattern = f'^{name}' + ('{' + labels + '}' if labels else '') + r'\s+([\d.e+\-]+)'
        m = re.search(pattern, data, re.MULTILINE)
        return m.group(1) if m else '0'

    gc_collected = float(val('python_gc_objects_collected_total','generation=\"0\"')) + \
                   float(val('python_gc_objects_collected_total','generation=\"1\"')) + \
                   float(val('python_gc_objects_collected_total','generation=\"2\"'))
    gc_uncollectable = float(val('python_gc_objects_uncollectable_total','generation=\"0\"')) + \
                       float(val('python_gc_objects_uncollectable_total','generation=\"1\"')) + \
                       float(val('python_gc_objects_uncollectable_total','generation=\"2\"'))
    gc_collections = float(val('python_gc_collections_total','generation=\"0\"')) + \
                     float(val('python_gc_collections_total','generation=\"1\"')) + \
                     float(val('python_gc_collections_total','generation=\"2\"'))
    open_fds = val('process_open_fds')
    rss = val('process_resident_memory_bytes')
    print(f'{gc_collected:.0f},{gc_uncollectable:.0f},{gc_collections:.0f},{open_fds},{rss}')
except Exception as e:
    print('0,0,0,0,0', file=sys.stderr)
    print('0,0,0,0,0')
" 2>/dev/null)
        fi

        if [ -n "$PROC_DATA" ]; then
            echo "${TIMESTAMP},${ELAPSED_MIN},${PROC_DATA},${PROM_DATA}" \
                >> "$OUTPUT_DIR/${CONTAINER}_broker_internals.csv"
            VM_RSS=$(echo "$PROC_DATA" | cut -d',' -f1)
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: VmRSS=${VM_RSS}KB gc=${PROM_DATA}"
        else
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: Query failed"
        fi
    done

    echo ""
    sleep 30
done
