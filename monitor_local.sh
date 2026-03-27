#!/bin/bash

# Monitor a single local Docker container for memory usage
# Usage: ./monitor_local.sh [container_name]

CONTAINER_NAME="${1:-rules-uploader}"
OUTPUT_FILE="baseline_${CONTAINER_NAME}_LOCAL.csv"

echo "Starting memory monitoring for local container: ${CONTAINER_NAME}"
echo "Output will be saved to: ${OUTPUT_FILE}"
echo ""

# Detect Prometheus port
STATS_PORT=$(docker exec "$CONTAINER_NAME" python3 -c "
import urllib.request
for port in [8001, 8000, 9090, 8080]:
    try:
        urllib.request.urlopen(f'http://localhost:{port}/metrics', timeout=2)
        print(port)
        break
    except:
        pass
" 2>/dev/null)

if [ -n "$STATS_PORT" ]; then
    echo "Prometheus endpoint found on port $STATS_PORT"
else
    echo "WARNING: No Prometheus endpoint found, GC data will be unavailable"
fi
echo ""

echo "timestamp,elapsed_min,memory_mib,vm_rss_kb,vm_data_kb,cgroup_bytes,gc_collected_total,gc_uncollectable_total,gc_collections_total,process_rss_bytes,open_fds" > "$OUTPUT_FILE"

START_TIME=$(date +%s)
ITERATION=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Docker stats memory
    MEMORY_MB=$(docker stats --no-stream --format "{{.MemUsage}}" "$CONTAINER_NAME" 2>/dev/null | awk '{print $1}' | sed 's/MiB//')

    # Process memory from /proc/1/status (actual app process)
    PROC_MEM=$(docker exec "$CONTAINER_NAME" sh -c '
        vm_rss=$(grep "^VmRSS:" /proc/1/status 2>/dev/null | awk "{print \$2}")
        vm_data=$(grep "^VmData:" /proc/1/status 2>/dev/null | awk "{print \$2}")
        cgroup=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
        echo "${vm_rss:-0},${vm_data:-0},${cgroup}"
    ' 2>/dev/null)

    # Prometheus GC stats from running app
    PROM="0,0,0,0,0"
    if [ -n "$STATS_PORT" ]; then
        PROM=$(docker exec "$CONTAINER_NAME" python3 -c "
import urllib.request, re, sys
try:
    data = urllib.request.urlopen('http://localhost:${STATS_PORT}/metrics', timeout=5).read().decode()
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
    rss = val('process_resident_memory_bytes')
    fds = val('process_open_fds')
    print(f'{gc_collected:.0f},{gc_uncollectable:.0f},{gc_collections:.0f},{rss},{fds}')
except:
    print('0,0,0,0,0')
" 2>/dev/null)
    fi

    echo "${TIMESTAMP},${ELAPSED_MIN},${MEMORY_MB},${PROC_MEM},${PROM}" >> "$OUTPUT_FILE"
    echo "[${ITERATION}] ${TIMESTAMP} - Memory: ${MEMORY_MB}MiB, VmRSS: $(echo "$PROC_MEM" | cut -d',' -f1)KB, Elapsed: ${ELAPSED_MIN}min"

    ITERATION=$((ITERATION + 1))
    sleep 60
done
