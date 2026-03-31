#!/bin/bash

# Collect internal metrics for a single container
# Usage: ./collect_internal_metrics.sh [container_name] [output_dir]

CONTAINER="${1:-rules-processing}"
OUTPUT_DIR="${2:-local_monitoring_internal_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTPUT_DIR"

# Detect Prometheus port
STATS_PORT=$(podman exec "$CONTAINER" python3 -c "
import urllib.request
for port in [8001, 8000, 9090, 8080]:
    try:
        urllib.request.urlopen(f'http://localhost:{port}/metrics', timeout=2)
        print(port)
        break
    except:
        pass
" 2>/dev/null)

echo "Container: $CONTAINER"
if [ -n "$STATS_PORT" ]; then
    echo "Prometheus endpoint on port $STATS_PORT"
else
    echo "WARNING: No Prometheus endpoint found"
fi

echo "timestamp,elapsed_min,vm_rss_kb,vm_data_kb,cgroup_bytes,gc_collected_total,gc_uncollectable_total,gc_collections_total,process_rss_bytes,process_cpu_seconds,open_fds,broker_instances,broker_exceptions,broker_tracebacks" \
    > "$OUTPUT_DIR/${CONTAINER}_internal_metrics.csv"

START_TIME=$(date +%s)

echo "Output: $OUTPUT_DIR/"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Process memory
    PROC_MEM=$(podman exec "$CONTAINER" sh -c '
        vm_rss=$(grep "^VmRSS:" /proc/1/status 2>/dev/null | awk "{print \$2}")
        vm_data=$(grep "^VmData:" /proc/1/status 2>/dev/null | awk "{print \$2}")
        cgroup=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
        echo "${vm_rss:-0},${vm_data:-0},${cgroup}"
    ' 2>/dev/null)

    # Prometheus
    PROM="0,0,0,0,0,0,0,0,0"
    if [ -n "$STATS_PORT" ]; then
        PROM=$(podman exec "$CONTAINER" python3 -c "
import urllib.request, re
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
    cpu = val('process_cpu_seconds_total')
    fds = val('process_open_fds')
    broker_inst = val('ccx_broker_instances_size')
    broker_exc = val('ccx_broker_exceptions_size')
    broker_tb = val('ccx_broker_tracebacks_size')
    print(f'{gc_collected:.0f},{gc_uncollectable:.0f},{gc_collections:.0f},{rss},{cpu},{fds},{broker_inst},{broker_exc},{broker_tb}')
except:
    print('0,0,0,0,0,0,0,0,0')
" 2>/dev/null)
    fi

    echo "${TIMESTAMP},${ELAPSED_MIN},${PROC_MEM},${PROM}" >> "$OUTPUT_DIR/${CONTAINER}_internal_metrics.csv"
    VM_RSS=$(echo "$PROC_MEM" | cut -d',' -f1)
    echo "[${ELAPSED_MIN} min] VmRSS=${VM_RSS}KB gc=${PROM}"

    sleep 30
done
