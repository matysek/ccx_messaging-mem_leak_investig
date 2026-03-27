#!/bin/bash

# Comprehensive monitoring for all local CCX containers
# Captures: docker stats, process memory (/proc/1/status), Prometheus metrics,
#           cgroup memory, and container logs
#
# Usage: ./monitor_all_local.sh [duration_minutes] [output_dir]
#   duration_minutes: how long to run (default: 720 = 12 hours)
#   output_dir: custom output directory name

CCX_CONTAINERS=("rules-uploader" "archive-sync" "rules-processing")
DURATION_MIN="${1:-720}"
OUTPUT_DIR="${2:-local_monitoring_$(date +%Y%m%d_%H%M%S)}"
SAMPLE_INTERVAL=10  # seconds between samples

mkdir -p "$OUTPUT_DIR"

echo "Starting comprehensive monitoring for all CCX containers"
echo "Output directory: $OUTPUT_DIR"
echo "Duration: ${DURATION_MIN} minutes"
echo "Sample interval: ${SAMPLE_INTERVAL}s"
echo "Monitoring containers: ${CCX_CONTAINERS[*]}"
echo ""

# Detect stats endpoint port per container
declare -A STATS_PORT
for container in "${CCX_CONTAINERS[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        continue
    fi
    PORT=$(docker exec "$container" python3 -c "
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
        STATS_PORT[$container]=$PORT
        echo "  $container: Prometheus metrics on port $PORT"
    else
        echo "  $container: No Prometheus endpoint found"
    fi
done
echo ""

# Initialize CSV files for each container
for container in "${CCX_CONTAINERS[@]}"; do
    # Docker stats CSV
    echo "timestamp,elapsed_min,cpu_perc,mem_usage_mb,mem_limit_mb,mem_perc,net_io,block_io" \
        > "$OUTPUT_DIR/${container}_docker_stats.csv"

    # Process memory from /proc/1/status (actual app process inside container)
    echo "timestamp,elapsed_min,vm_size_kb,vm_rss_kb,vm_data_kb,vm_stk_kb,cgroup_mem_bytes" \
        > "$OUTPUT_DIR/${container}_process_memory.csv"

    # Prometheus metrics (from the app's own HTTP endpoint - real GC data)
    echo "timestamp,elapsed_min,gc_collected_gen0,gc_collected_gen1,gc_collected_gen2,gc_uncollectable_gen0,gc_uncollectable_gen1,gc_uncollectable_gen2,gc_collections_gen0,gc_collections_gen1,gc_collections_gen2,process_rss_bytes,process_vm_bytes,process_cpu_seconds,open_fds,ccx_received,ccx_failures_ocp,ccx_processed_ocp,ccx_published_ocp" \
        > "$OUTPUT_DIR/${container}_prometheus.csv"

    # Capture initial container logs
    docker logs "$container" > "$OUTPUT_DIR/${container}_logs_initial.txt" 2>&1
done

START_TIME=$(date +%s)
ITERATION=0
ELAPSED_MIN=0
LAST_LOG_TIME=$START_TIME

echo "Monitoring started at $(date)"
echo "Press Ctrl+C to stop"
echo ""

while [ "$ELAPSED_MIN" -lt "$DURATION_MIN" ]; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    if [ $((ITERATION % 60)) -eq 0 ]; then
        echo "=== Iteration $ITERATION - $TIMESTAMP (${ELAPSED_MIN} min) ==="
    fi

    for container in "${CCX_CONTAINERS[@]}"; do
        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            if [ $((ITERATION % 60)) -eq 0 ]; then
                echo "  [SKIP] $container - not running"
            fi
            continue
        fi

        # 1. Docker stats (same as before - this works fine)
        STATS=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}" "$container" 2>/dev/null)
        if [ $? -eq 0 ]; then
            MEM_USAGE=$(echo "$STATS" | cut -d',' -f2 | awk '{print $1}' | sed 's/MiB//')
            MEM_LIMIT=$(echo "$STATS" | cut -d',' -f2 | awk '{print $3}' | sed 's/GiB//' | awk '{print $1 * 1024}')
            CPU_PERC=$(echo "$STATS" | cut -d',' -f1 | sed 's/%//')
            MEM_PERC=$(echo "$STATS" | cut -d',' -f3 | sed 's/%//')
            NET_IO=$(echo "$STATS" | cut -d',' -f4)
            BLOCK_IO=$(echo "$STATS" | cut -d',' -f5)
            echo "${TIMESTAMP},${ELAPSED_MIN},${CPU_PERC},${MEM_USAGE},${MEM_LIMIT},${MEM_PERC},${NET_IO},${BLOCK_IO}" \
                >> "$OUTPUT_DIR/${container}_docker_stats.csv"
        fi

        # 2. Process memory from /proc/1/status (the ACTUAL app process, not a new one)
        PROC_MEM=$(docker exec "$container" sh -c '
            grep -E "VmSize|VmRSS|VmData|VmStk" /proc/1/status 2>/dev/null | awk "{print \$2}" | tr "\n" ","
            cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0
        ' 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$PROC_MEM" ]; then
            echo "${TIMESTAMP},${ELAPSED_MIN},${PROC_MEM}" >> "$OUTPUT_DIR/${container}_process_memory.csv"
        fi

        # 3. Prometheus metrics from app's own HTTP endpoint (real GC + process data)
        PORT="${STATS_PORT[$container]}"
        if [ -n "$PORT" ]; then
            PROM=$(docker exec "$container" python3 -c "
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
        val('process_virtual_memory_bytes'),
        val('process_cpu_seconds_total'),
        val('process_open_fds'),
        val('ccx_consumer_received_total'),
        val('ccx_failures_total', 'archive=\"ocp\"'),
        val('ccx_engine_processed_total', 'archive=\"ocp\"'),
        val('ccx_published_total', 'archive=\"ocp\"'),
    ]
    print(','.join(fields))
except Exception as e:
    print(f'error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$PROM" ]; then
                echo "${TIMESTAMP},${ELAPSED_MIN},${PROM}" >> "$OUTPUT_DIR/${container}_prometheus.csv"
            fi
        fi

        # 4. Incremental log capture every 10 minutes (not full dumps)
        LOG_INTERVAL=$((10 * 60))
        if [ $((CURRENT_TIME - LAST_LOG_TIME)) -ge "$LOG_INTERVAL" ]; then
            SINCE_TIME=$(date -d "@$LAST_LOG_TIME" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -r "$LAST_LOG_TIME" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)
            if [ -n "$SINCE_TIME" ]; then
                docker logs --since "$SINCE_TIME" "$container" >> "$OUTPUT_DIR/${container}_logs_incremental.txt" 2>&1
            fi
        fi

        # Print compact status every 60 iterations
        if [ $((ITERATION % 60)) -eq 0 ]; then
            echo "  $container: mem=${MEM_USAGE}MiB cpu=${CPU_PERC}%"
        fi
    done

    # Update last log time after processing all containers
    if [ $((CURRENT_TIME - LAST_LOG_TIME)) -ge "$LOG_INTERVAL" ]; then
        LAST_LOG_TIME=$CURRENT_TIME
    fi

    ITERATION=$((ITERATION + 1))
    sleep "$SAMPLE_INTERVAL"
done

echo ""
echo "Monitoring completed at $(date)"
echo "Capturing final logs..."

for container in "${CCX_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        docker logs "$container" > "$OUTPUT_DIR/${container}_logs_final.txt" 2>&1
        echo "  Saved final logs for $container"
    fi
done

# Generate summary report
echo ""
echo "Generating summary report..."
{
    echo "# Monitoring Summary"
    echo "Start: $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$START_TIME" '+%Y-%m-%d %H:%M:%S')"
    echo "End:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Duration: ${ELAPSED_MIN} minutes"
    echo ""

    for container in "${CCX_CONTAINERS[@]}"; do
        CSV="$OUTPUT_DIR/${container}_docker_stats.csv"
        PROM_CSV="$OUTPUT_DIR/${container}_prometheus.csv"
        PROC_CSV="$OUTPUT_DIR/${container}_process_memory.csv"
        if [ ! -f "$CSV" ]; then continue; fi

        echo "## $container"
        echo ""

        # Docker stats memory summary
        awk -F',' 'NR>1 && $4+0>0 {
            sum+=$4; n++;
            if(n==1||$4+0>max) max=$4+0;
            if(n==1||$4+0<min) min=$4+0;
            if(NR==2) first=$4+0;
            last=$4+0;
        } END {
            if(n>0) printf "Docker stats: start=%.1f MB, end=%.1f MB, min=%.1f MB, max=%.1f MB, avg=%.1f MB, delta=%+.1f MB\n", first, last, min, max, sum/n, last-first
        }' "$CSV"

        # Process memory summary (VmRSS)
        if [ -f "$PROC_CSV" ]; then
            awk -F',' 'NR>1 && $4+0>0 {
                sum+=$4; n++;
                if(n==1||$4+0>max) max=$4+0;
                if(n==1||$4+0<min) min=$4+0;
                if(NR==2) first=$4+0;
                last=$4+0;
            } END {
                if(n>0) printf "VmRSS:        start=%.0f KB, end=%.0f KB, delta=%+.0f KB (%+.1f MB)\n", first, last, last-first, (last-first)/1024
            }' "$PROC_CSV"
        fi

        # Prometheus GC summary
        if [ -f "$PROM_CSV" ] && [ "$(wc -l < "$PROM_CSV")" -gt 1 ]; then
            awk -F',' 'NR==2{
                first_collected=$3+$4+$5;
                first_uncollectable=$6+$7+$8;
                first_rss=$12
            }
            {
                last_collected=$3+$4+$5;
                last_uncollectable=$6+$7+$8;
                last_rss=$12
            }
            END {
                if(NR>1) {
                    printf "GC collected:  total=%.0f (delta=%.0f)\n", last_collected, last_collected-first_collected
                    printf "GC uncollectable: total=%.0f (delta=%.0f)\n", last_uncollectable, last_uncollectable-first_uncollectable
                    printf "Prometheus RSS: start=%.0f bytes, end=%.0f bytes, delta=%+.0f bytes (%+.1f MB)\n", first_rss, last_rss, last_rss-first_rss, (last_rss-first_rss)/1048576
                }
            }' "$PROM_CSV"

            # CCX pipeline counters
            awk -F',' 'END {
                if(NR>1) printf "Pipeline: received=%.0f, processed=%.0f, failures=%.0f, published=%.0f\n", $16, $18, $17, $19
            }' "$PROM_CSV"
        fi

        echo ""
    done
} > "$OUTPUT_DIR/SUMMARY.txt"

cat "$OUTPUT_DIR/SUMMARY.txt"
echo ""
echo "All monitoring data saved to: $OUTPUT_DIR/"
