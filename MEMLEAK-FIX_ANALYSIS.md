# Memory Leak Analysis & Fix Plan — CCXDEV-15098

## Context

The 2026-03-26 monitoring run (`local_monitoring_20260326_073712`) ran for **9.2 hours** with **zero errors** (no PermissionError, no exceptions). All 3 containers show a steady, monotonic memory growth:

| Container | Start | End | Leak Rate | Projected /week |
|---|---|---|---|---|
| **archive-sync** | 84.6 MB | 96.6 MB | **1.30 MB/hr** | +218 MB |
| **rules-processing** | 91.1 MB | 103.0 MB | **1.29 MB/hr** | +216 MB |
| **rules-uploader** | 110.2 MB | 117.2 MB | **0.76 MB/hr** | +127 MB |

**Critical finding**: The leak is **time-based**, not per-archive. archive-sync processed 288 archives/hr while rules-processing processed only 7/hr, yet both leak at ~1.3 MB/hr. This rules out per-archive broker accumulation as the sole cause.

GC reports **0 uncollectable objects** throughout, meaning objects are reachable via strong references (not orphaned cycles).

---

## Root Cause Analysis

After reading the source code, there are **two leak vectors** — one per-archive and one time-based:

### Leak 1: Broker exception/traceback dicts never cleaned up (per-archive)

**Files:**
- `insights/core/dr.py` — `Broker` class (line 814), `add_exception()` (line 909), `run_components()` (line 1057)
- `ccx_messaging/monitored_broker.py` — `SentryMonitoredBroker.add_exception()` (line 23)
- `insights_messaging/consumers/__init__.py` — `Consumer.process()` (line 36)

**The chain:**
1. `Consumer.process()` creates a new `SentryMonitoredBroker()` per archive
2. `Engine.process()` runs ~500 components via `dr.run_components()`
3. Most components raise `MissingRequirements` — each stored in `broker.exceptions[component]` and `broker.tracebacks[ex]`
4. After processing, the broker goes out of scope BUT:
   - `broker.tracebacks[ex] = traceback.format_exc()` — the exception `ex` is used as a dict key
   - The exception's `__traceback__` attribute holds a reference to the stack frame
   - The stack frame holds a reference to local variables including `broker`
   - **Circular ref**: `Broker → exceptions dict → exception → __traceback__ → frame → broker`
5. Python's GC CAN break these cycles, but the objects are also reachable via `broker.exceptions`/`broker.tracebacks` dicts, so GC sees them as "in use"

**Note:** `MissingRequirements` exceptions (line 1082) are stored WITHOUT a traceback (`tb=None`), so they don't create circular refs. But `BlacklistedSpec`, `SkipComponent`, and generic `Exception` (lines 1076, 1086, 1091-1092) DO store `traceback.format_exc()`.

### Leak 2: Kafka stats callback metrics (time-based, ~every 10s)

**Files:**
- `insights_messaging/consumers/kafka.py` — `KafkaMetrics` class (line 29), `stats_to_metrics()` (line 64)
- Configured at line 102: `config["statistics.interval.ms"] = metric_interval` (default 10000ms)

**The chain:**
1. Confluent Kafka fires `stats_cb` every 10 seconds regardless of message activity
2. `stats_to_metrics()` calls `.labels(type=stat_type, client_id=client_id, state=state).set(...)`
3. The `state` label value can change (e.g., `"up"`, `"rebalancing"`, etc.)
4. Each unique label combination creates a new child metric stored permanently in prometheus_client's `_metrics` dict
5. This leaks ~1 MB/hr consistently across all containers regardless of processing volume

This explains why the leak rate is identical (~1.3 MB/hr) for archive-sync (288 archives/hr) and rules-processing (7 archives/hr).

---

## Fix Plan

### Fix 1: Break circular references in Broker after processing

**Where:** `insights_messaging/consumers/__init__.py` — `Consumer.process()` method

**What:** Add broker cleanup in the `finally` block to break circular reference chains:

```python
def process(self, input_msg):
    broker = None
    try:
        self.fire("on_recv", input_msg)
        url = self.get_url(input_msg)
        with self.downloader.get(url) as path:
            self.fire("on_download", path)
            broker = self.create_broker(input_msg)
            results = self.engine.process(broker, path)
            self.fire("on_process", input_msg, results)
            self.publisher.publish(input_msg, results)
            self.fire("on_consumer_success", input_msg, broker, results)
    except Exception as ex:
        self.publisher.error(input_msg, ex)
        self.fire("on_consumer_failure", input_msg, ex)
        raise
    finally:
        self.fire("on_consumer_complete", input_msg)
        # Break circular references: Broker → exceptions → __traceback__ → frame → Broker
        if broker is not None:
            for ex_list in broker.exceptions.values():
                for ex in ex_list:
                    ex.__traceback__ = None
            broker.exceptions.clear()
            broker.tracebacks.clear()
            broker.instances.clear()
```

**Also in:** `insights/core/dr.py` — `run_components()` line 1089-1094. Clear `ex.__traceback__` after storing the formatted traceback string:

```python
except Exception as ex:
    log.debug(ex)
    tb = traceback.format_exc()
    broker.add_exception(component, ex, tb)
    ex.__traceback__ = None  # Break circular ref immediately
```

### Fix 2: Prevent Kafka metrics label cardinality leak

**Where:** `insights_messaging/consumers/kafka.py` — `KafkaMetrics.stats_to_metrics()`

**What:** The `state` label on `KAFKA_CONSUMER_REBALANCE_COUNT` gauge changes over time, creating unbounded label cardinality. Either:

- **Option A**: Remove `state` from labelnames (it's a gauge, not a counter — the current state is what matters, not per-state history)
- **Option B**: Use `.remove()` to clean up old label combinations before setting new ones

### Fix 3: Add broker size Prometheus gauges (observability)

**Where:** `ccx_messaging/watchers/stats_watcher.py`

**What:** Add gauges to track broker dict sizes from inside the running process, so monitoring scripts can observe leak behavior:

```python
from prometheus_client import Gauge

broker_instances_size = Gauge('ccx_broker_instances_size', 'Size of broker.instances dict')
broker_exceptions_size = Gauge('ccx_broker_exceptions_size', 'Size of broker.exceptions dict')
broker_tracebacks_size = Gauge('ccx_broker_tracebacks_size', 'Size of broker.tracebacks dict')
```

Update in `on_consumer_success` and `on_consumer_failure` callbacks where `broker` is available.

---

## Where to Make Changes

These are upstream repos, not this investigation repo. The fixes go in:

1. **`insights-messaging`** (Red Hat internal) — `consumers/__init__.py` for broker cleanup
2. **`insights-core`** — `insights/core/dr.py` for `ex.__traceback__ = None` in `run_components()`
3. **`ccx-messaging`** — `consumers/kafka.py` for Kafka metrics fix, `watchers/stats_watcher.py` for observability gauges

## Verification

1. Apply fixes to local deploy containers (mount patched files or build custom image)
2. Run `./monitor_all_local.sh 1440` (24 hours) with `./collect_internal_metrics_all.sh` in parallel
3. Compare memory growth rate — should see flat RSS after warmup instead of +1 MB/hr
4. Prometheus GC metrics should show `gc_uncollectable` staying at 0 and RSS stabilizing
5. If broker gauges are added, verify `ccx_broker_exceptions_size` resets to 0 after each archive

## Changes Applied                                                                                                                                                                                                   
                                                                                                                                                                                                                
1. insights-core-messaging (2 files)                                                                                                                                                                              
                                                                                                                                                                                                                
insights_messaging/consumers/__init__.py — Broker cleanup after processing:                                                                                                                                       
- Moved broker declaration before try block (initialized to None)                                                                                                                                                 
- Added cleanup in finally block: clears ex.__traceback__ on all stored exceptions, then clears broker.exceptions, broker.tracebacks, and broker.instances dicts                                                  
- This breaks the circular reference chain: Broker → exceptions → exception → __traceback__ → frame → Broker                                                                                                    
                                                                                                                                                                                                                
insights_messaging/consumers/kafka.py — Fix Kafka metrics label cardinality:                                                                                                                                      
- Removed state from KAFKA_CONSUMER_REBALANCE_COUNT labelnames (was creating a new child metric every time the consumer group state changed)                                                                      
- Added a separate KAFKA_CONSUMER_STATE gauge for state info (fixed cardinality — only type + client_id)                                                                                                          
                                                                                                                                                                                                                
2. insights-core                                                                                                                                                                                                  
                                                                                                                                                                                                                
insights/core/dr.py — Clear traceback ref immediately:                                                                                                                                                            
- Added ex.__traceback__ = None after broker.add_exception(component, ex, tb) in the run() function                                                                                                               
- The formatted traceback string is already saved in tb, so the frame reference chain is no longer needed                                                                                                         
                                                                                                                                                                                                              
3. ccx-messaging (2 files)                                                                                                                                                                                        
                                                                                                                                                                                                                
ccx_messaging/watchers/stats_watcher.py — Broker observability gauges:                                                                                                                                            
- Added Gauge import                                                                                                                                                                                              
- Added 3 new gauges: ccx_broker_instances_size, ccx_broker_exceptions_size, ccx_broker_tracebacks_size                                                                                                           
- Updated on_consumer_success to record broker dict sizes before cleanup                                                                                                                                        
- Added cleanup in __del__                                                                                                                                                                                        
                                                                                                                                                                                                                
test/watchers/stats_watcher_test.py — Fixed test:                                                                                                                                                                 
- Replaced string "broker" with a MagicMock having instances, exceptions, tracebacks dicts                                                                                                                        
                                                                                                                                                                                                                
All 30 stats_watcher tests pass.      

## Pull requests with PRs

  ┌─────────────────────────┬───────────────────────────────────────────┐                                                                                                                                           
  │          Repo           │                    PR                     │
  ├─────────────────────────┼───────────────────────────────────────────┤                                                                                                                                           
  │ insights-core-messaging │ RedHatInsights/insights-core-messaging#74 │                                                                                                                                         
  ├─────────────────────────┼───────────────────────────────────────────┤                                                                                                                                           
  │ insights-core           │ RedHatInsights/insights-core#4763         │                                                                                                                                           
  ├─────────────────────────┼───────────────────────────────────────────┤                                                                                                                                           
  │ ccx-messaging           │ RedHatInsights/insights-ccx-messaging#671 │                                                                                                                                           
  └─────────────────────────┴───────────────────────────────────────────┘  
