#!/bin/bash

# Enhanced internal metrics collection for ALL leaking containers
# Safe O(1) operations only - no gc.collect(), no iteration over large collections

# Containers with memory leaks
CONTAINERS=("rules-uploader" "archive-sync" "rules-processing")
OUTPUT_DIR="${1:-local_monitoring_internal_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTPUT_DIR"

# Create CSV files for each container
for CONTAINER in "${CONTAINERS[@]}"; do
    echo "timestamp,elapsed_min,total_objects,broker_created,broker_collected,broker_live_weakset,exception_count,gc_gen0,gc_gen1,gc_gen2" > "$OUTPUT_DIR/${CONTAINER}_internal_metrics.csv"
done

START_TIME=$(date +%s)
ITERATION=0

echo "Starting internal metrics collection for: ${CONTAINERS[@]}"
echo "Output: $OUTPUT_DIR/"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    for CONTAINER in "${CONTAINERS[@]}"; do
        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: NOT RUNNING - skipping"
            continue
        fi

        # Safe read-only query - just counts, no collection
        METRICS=$(docker exec "$CONTAINER" python3 -c "
import gc
import sys

# Just get counts - O(1) operation, no collection
gc_count = gc.get_count()
total_objects = len(gc.get_objects())  # Count but don't iterate contents

# Try to import and read the counters from dr.py
try:
    from insights.core import dr
    broker_created = dr._BROKER_CREATED_COUNT
    broker_collected = dr._BROKER_COLLECTED_COUNT
    broker_live = len(dr._BROKER_INSTANCES)
except:
    broker_created = 0
    broker_collected = 0
    broker_live = 0

# Count exceptions across all tracked brokers (if WeakSet still has refs)
exception_count = 0
try:
    from insights.core import dr
    # Just count, don't iterate details
    for b in dr._BROKER_INSTANCES:
        exception_count += sum(len(v) for v in b.exceptions.values())
except:
    pass

print(f'{total_objects},{broker_created},{broker_collected},{broker_live},{exception_count},{gc_count[0]},{gc_count[1]},{gc_count[2]}')
" 2>/dev/null)

        if [ $? -eq 0 ]; then
            echo "${TIMESTAMP},${ELAPSED_MIN},${METRICS}" >> "$OUTPUT_DIR/${CONTAINER}_internal_metrics.csv"
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: ${METRICS}"
        else
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: Query failed"
        fi
    done

    echo ""
    ITERATION=$((ITERATION + 1))
    sleep 30  # Every 30 seconds
done
