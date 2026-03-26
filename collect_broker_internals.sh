#!/bin/bash

# Monitor BROKER INTERNALS - what's accumulating inside the single long-lived broker
# This tracks the actual leak source

CONTAINERS=("rules-uploader" "archive-sync" "rules-processing")
OUTPUT_DIR="${1:-local_monitoring_internal_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTPUT_DIR"

# Create CSV files for each container
for CONTAINER in "${CONTAINERS[@]}"; do
    echo "timestamp,elapsed_min,broker_instances_count,broker_exceptions_count,broker_tracebacks_count,broker_instances_keys,broker_exceptions_keys,total_exception_lists" > "$OUTPUT_DIR/${CONTAINER}_broker_internals.csv"
done

START_TIME=$(date +%s)

echo "Starting BROKER INTERNALS monitoring for: ${CONTAINERS[@]}"
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

        # Query broker internals - O(1) operations only
        METRICS=$(docker exec "$CONTAINER" python3 -c "
import sys

try:
    from insights.core import dr

    # Find the single broker instance (should be exactly 1)
    brokers = list(dr._BROKER_INSTANCES)

    if len(brokers) == 0:
        # No broker in WeakSet, try to find it another way
        print('0,0,0,0,0,0')
    else:
        broker = brokers[0]

        # Count sizes of broker dictionaries - O(1) operations
        instances_count = len(broker.instances)
        exceptions_count = len(broker.exceptions)
        tracebacks_count = len(broker.tracebacks)

        # Count keys
        instances_keys = len(broker.instances.keys())
        exceptions_keys = len(broker.exceptions.keys())

        # Count total exception list items
        total_exception_lists = sum(len(v) for v in broker.exceptions.values())

        print(f'{instances_count},{exceptions_count},{tracebacks_count},{instances_keys},{exceptions_keys},{total_exception_lists}')
except Exception as e:
    print(f'0,0,0,0,0,0', file=sys.stderr)
    print(f'0,0,0,0,0,0')
" 2>/dev/null)

        if [ $? -eq 0 ]; then
            echo "${TIMESTAMP},${ELAPSED_MIN},${METRICS}" >> "$OUTPUT_DIR/${CONTAINER}_broker_internals.csv"
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: ${METRICS}"
        else
            echo "[${ELAPSED_MIN} min] ${CONTAINER}: Query failed"
        fi
    done

    echo ""
    sleep 30  # Every 30 seconds
done
