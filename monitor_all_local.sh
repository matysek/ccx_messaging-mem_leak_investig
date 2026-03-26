#!/bin/bash

# Comprehensive monitoring for all local CCX containers
# Captures docker stats, /proc/meminfo, and Python GC stats every minute

CCX_CONTAINERS=("rules-uploader" "archive-sync" "rules-processing")
OUTPUT_DIR="local_monitoring_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTPUT_DIR"

echo "Starting comprehensive monitoring for all CCX containers"
echo "Output directory: $OUTPUT_DIR"
echo "Monitoring containers: ${CCX_CONTAINERS[@]}"
echo ""

# Initialize CSV files for each container
for container in "${CCX_CONTAINERS[@]}"; do
    # Docker stats CSV
    echo "timestamp,elapsed_min,cpu_perc,mem_usage_mb,mem_limit_mb,mem_perc,net_io,block_io" > "$OUTPUT_DIR/${container}_docker_stats.csv"

    # GC stats CSV - UPDATED header with before/after counts
    echo "timestamp,elapsed_min,gen0_before,gen1_before,gen2_before,collected,total_before,gen0_after,gen1_after,gen2_after" > "$OUTPUT_DIR/${container}_gc_stats.csv"

    # Proc meminfo will be in separate files per iteration
    mkdir -p "$OUTPUT_DIR/${container}_proc_meminfo"

    # Capture initial container logs
    docker logs "$container" > "$OUTPUT_DIR/${container}_logs_initial.txt" 2>&1
done

START_TIME=$(date +%s)
ITERATION=0
ELAPSED_MIN=0

echo "Monitoring started at $(date)"
echo "Press Ctrl+C to stop"
echo ""

while [ "$ELAPSED_MIN" -lt 240 ]; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo "=== Iteration $ITERATION - $TIMESTAMP (${ELAPSED_MIN} min) ==="

    for container in "${CCX_CONTAINERS[@]}"; do
        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "  [SKIP] $container - not running"
            continue
        fi

        echo "  [MONITORING] $container"

        # 1. Docker stats
        STATS=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}" "$container" 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Parse memory usage (e.g., "123.4MiB / 7.654GiB" -> "123.4,7654")
            MEM_USAGE=$(echo "$STATS" | cut -d',' -f2 | awk '{print $1}' | sed 's/MiB//')
            MEM_LIMIT=$(echo "$STATS" | cut -d',' -f2 | awk '{print $3}' | sed 's/GiB//' | awk '{print $1 * 1024}')
            CPU_PERC=$(echo "$STATS" | cut -d',' -f1 | sed 's/%//')
            MEM_PERC=$(echo "$STATS" | cut -d',' -f3 | sed 's/%//')
            NET_IO=$(echo "$STATS" | cut -d',' -f4)
            BLOCK_IO=$(echo "$STATS" | cut -d',' -f5)

            echo "${TIMESTAMP},${ELAPSED_MIN},${CPU_PERC},${MEM_USAGE},${MEM_LIMIT},${MEM_PERC},${NET_IO},${BLOCK_IO}" >> "$OUTPUT_DIR/${container}_docker_stats.csv"
        fi

        # 2. Python GC stats - FIXED: capture counts BEFORE collecting
        GC_OUTPUT=$(docker exec "$container" python3 -c "
import gc
# Get counts BEFORE collecting (this shows pending objects)
counts_before = gc.get_count()
# Now run collection and see how many objects were collected
collected = gc.collect()
# Get counts AFTER collecting
counts_after = gc.get_count()
# Total tracked objects before collection
total_before = sum(counts_before)
print(f'{counts_before[0]},{counts_before[1]},{counts_before[2]},{collected},{total_before},{counts_after[0]},{counts_after[1]},{counts_after[2]}')
" 2>/dev/null)

        if [ $? -eq 0 ]; then
            echo "${TIMESTAMP},${ELAPSED_MIN},${GC_OUTPUT}" >> "$OUTPUT_DIR/${container}_gc_stats.csv"
        fi

        # 3. /proc/meminfo (save to individual file)
        docker exec "$container" cat /proc/meminfo > "$OUTPUT_DIR/${container}_proc_meminfo/meminfo_${ITERATION}.txt" 2>/dev/null

        # 4. Capture logs every 60 iterations (~5 minutes) to track monitoring messages
        if [ $((ITERATION % 60)) -eq 0 ]; then
            docker logs "$container" > "$OUTPUT_DIR/${container}_logs_iter${ITERATION}.txt" 2>&1
        fi
    done

    echo ""
    ITERATION=$((ITERATION + 1))
    sleep 5
done

echo ""
echo "Monitoring completed or interrupted at $(date)"
echo "Capturing final logs..."

# Capture final logs for all containers
for container in "${CCX_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        docker logs "$container" > "$OUTPUT_DIR/${container}_logs_final.txt" 2>&1
        echo "  Saved logs for $container"
    fi
done

echo "All monitoring data saved to: $OUTPUT_DIR"
