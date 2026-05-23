#!/bin/bash
#
# reproduce_leak.sh — Orchestrates full memory leak reproduction locally.
#
# Matches STAGE config: insights-core-messaging fix deployed, insights-core fix NOT deployed.
#
# What it does:
#   1. Starts the local deploy via podman compose up -d
#   2. Waits for services + metrics endpoints to be ready
#   3. Auto-detects whether the insights-core fix is present or missing
#      (inspects dr.run() source inside the container)
#   4. Launches monitor_all_local.sh in the background
#      (captures RSS, GC, broker dicts, CPU)
#   5. Runs send_archives.py continuous load for 4 hours
#   6. On completion or Ctrl+C: prints memory growth summary (MB/hr per
#      container), asks before stopping containers
#
# Usage:
#   ./reproduce_leak.sh              # 4 hours (default)
#   ./reproduce_leak.sh 120          # 2 hours
#
# To compare with the insights-core fix applied:
#   1. Run once without the fix (matches STAGE) to get baseline data
#   2. Apply the patch:
#        cd ../insights-core && git apply -p0 \
#          ../CCXDEV-15098-mem_leak_investig/insights-core.patch
#   3. Rebuild the image with patched insights-core
#   4. Run again and compare outputs
#
# Prerequisites:
#   - obsint-processing-local-deploy repo cloned at ../obsint-processing-local-deploy
#   - venv with molodec installed (for send_archives.py)
#   - podman compose available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/../obsint-processing-local-deploy/internal"
DURATION_MIN="${1:-240}"
OUTPUT_DIR="${SCRIPT_DIR}/local_monitoring_$(date +%Y%m%d_%H%M%S)"
MONITOR_PID=""
SEND_PID=""

cleanup() {
    echo ""
    echo "=== Shutting down ==="

    if [ -n "$SEND_PID" ] && kill -0 "$SEND_PID" 2>/dev/null; then
        echo "Stopping load generator (PID $SEND_PID)..."
        kill "$SEND_PID" 2>/dev/null || true
        wait "$SEND_PID" 2>/dev/null || true
    fi

    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        echo "Stopping monitor (PID $MONITOR_PID)..."
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi

    echo ""
    echo "=== Quick memory summary ==="
    if [ -d "$OUTPUT_DIR" ]; then
        for csv in "$OUTPUT_DIR"/*_podman_stats.csv; do
            [ -f "$csv" ] || continue
            container=$(basename "$csv" | sed 's/_podman_stats.csv//')
            awk -F',' -v name="$container" 'NR>1 && $4+0>0 {
                if(!first) { first=$4+0; first_t=$2 }
                last=$4+0; last_t=$2
            } END {
                if(first && last_t>first_t) {
                    hours=(last_t-first_t)/60
                    rate=(last-first)/hours
                    printf "  %-20s start=%.1f MB  end=%.1f MB  delta=%+.1f MB  rate=%+.2f MB/hr\n", name, first, last, last-first, rate
                }
            }' "$csv"
        done

        echo ""
        echo "Monitoring data saved to: $OUTPUT_DIR/"

        if [ -f "$OUTPUT_DIR/SUMMARY.txt" ]; then
            echo ""
            cat "$OUTPUT_DIR/SUMMARY.txt"
        fi
    fi

    echo ""
    read -r -p "Stop containers? (podman compose down) [y/N] " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        echo "Stopping containers..."
        podman compose -f "$DEPLOY_DIR/docker-compose.yaml" down
    else
        echo "Containers left running. Stop manually with:"
        echo "  podman compose -f $DEPLOY_DIR/docker-compose.yaml down"
    fi
}

trap cleanup EXIT INT TERM

# --- Pre-flight checks ---
echo "=== Pre-flight checks ==="

if [ ! -f "$DEPLOY_DIR/docker-compose.yaml" ]; then
    echo "ERROR: docker-compose.yaml not found at $DEPLOY_DIR"
    echo "Expected: ../obsint-processing-local-deploy/internal/docker-compose.yaml"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/monitor_all_local.sh" ]; then
    echo "ERROR: monitor_all_local.sh not found"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/send_archives.py" ]; then
    echo "ERROR: send_archives.py not found"
    exit 1
fi

echo "  Deploy dir:  $DEPLOY_DIR"
echo "  Duration:    ${DURATION_MIN} minutes"
echo "  Output dir:  $OUTPUT_DIR"
echo ""

# --- Check current image ---
echo "=== Checking deployed image ==="
IMAGE=$(grep -m1 'image:' "$DEPLOY_DIR/docker-compose.yaml" | awk '{print $2}' | head -1)
echo "  Image: $IMAGE"

if echo "$IMAGE" | grep -q "fix_insights_messaging_only"; then
    echo "  Config: insights-core-messaging fix ONLY (matches STAGE)"
elif echo "$IMAGE" | grep -q "latest"; then
    echo "  Config: latest image (may include all fixes)"
else
    echo "  Config: custom image tag"
fi
echo ""

# --- Start services ---
echo "=== Starting services ==="
podman compose -f "$DEPLOY_DIR/docker-compose.yaml" up -d

echo ""
echo "Waiting for services to be ready..."

# Wait for kafka topics to be created (kafka-topics-waiter exits 0 when done)
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    # Check if rules-processing is running
    if podman ps --format '{{.Names}}' | grep -q "rules-processing"; then
        echo "  rules-processing is up"
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo "  Waiting... (${WAITED}s)"
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo "ERROR: Timed out waiting for services"
    echo "Check: podman compose -f $DEPLOY_DIR/docker-compose.yaml logs"
    exit 1
fi

# Wait a bit more for Prometheus endpoints to be available
echo "  Waiting 15s for metrics endpoints..."
sleep 15

# Verify metrics endpoint
if podman exec rules-processing python3 -c "
import urllib.request
urllib.request.urlopen('http://localhost:8001/metrics', timeout=5)
print('OK')
" 2>/dev/null | grep -q "OK"; then
    echo "  rules-processing metrics endpoint ready (port 8001)"
else
    echo "  WARNING: rules-processing metrics endpoint not responding"
fi

# --- Check if insights-core fix is present ---
echo ""
echo "=== Checking insights-core fix status ==="
FIX_CHECK=$(podman exec rules-processing python3 -c "
import inspect, insights.core.dr as dr
src = inspect.getsource(dr.run)
if '__traceback__ = None' in src or '__traceback__=None' in src:
    print('PRESENT')
else:
    print('MISSING')
" 2>/dev/null || echo "UNKNOWN")

if [ "$FIX_CHECK" = "PRESENT" ]; then
    echo "  insights-core fix: PRESENT (ex.__traceback__ = None in dr.run)"
    echo "  This run will show the FIXED behavior"
elif [ "$FIX_CHECK" = "MISSING" ]; then
    echo "  insights-core fix: MISSING (matches STAGE)"
    echo "  This run should reproduce the leak"
else
    echo "  insights-core fix: could not determine"
fi

# Check insights-core-messaging fix
MESSAGING_FIX=$(podman exec rules-processing python3 -c "
import inspect, insights_messaging.consumers as c
src = inspect.getsource(c.Consumer.run)
if 'broker.exceptions' in src and 'clear' in src:
    print('PRESENT')
else:
    print('MISSING')
" 2>/dev/null || echo "UNKNOWN")
echo "  insights-core-messaging fix: $MESSAGING_FIX"

echo ""

# --- Start monitoring ---
echo "=== Starting monitoring (${DURATION_MIN} min) ==="
bash "$SCRIPT_DIR/monitor_all_local.sh" "$DURATION_MIN" "$OUTPUT_DIR" &
MONITOR_PID=$!
echo "  Monitor PID: $MONITOR_PID"
echo "  Output: $OUTPUT_DIR/"

# Give monitor a moment to initialize
sleep 5

# --- Start load generation ---
echo ""
echo "=== Starting load generation ==="
echo "  Mode: continuous (4hr, 10 archives/sec)"
echo "  Script: send_archives.py upload"
echo ""

cd "$SCRIPT_DIR"
"$SCRIPT_DIR/venv/bin/python3" "$SCRIPT_DIR/send_archives.py" upload &
SEND_PID=$!
echo "  Load generator PID: $SEND_PID"

echo ""
echo "=== Running ==="
echo "  Monitor: $MONITOR_PID"
echo "  Load gen: $SEND_PID"
echo "  Duration: ${DURATION_MIN} minutes"
echo "  Press Ctrl+C to stop early"
echo ""

# Wait for load generator to finish (or be killed)
wait "$SEND_PID" 2>/dev/null || true
SEND_PID=""

echo ""
echo "Load generation complete."

# Let monitor finish its current iteration
sleep 15

# Kill monitor
if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
fi
MONITOR_PID=""

echo "Monitoring complete."
