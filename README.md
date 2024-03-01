chroprof - Profiling for [Chronos](https://github.com/status-im/nim-chronos)
============================================================================

This repo contains a usable profiler for [Chronos](https://github.com/status-im/nim-chronos). For the time being, it requires a modified version of Chronos ([V3](https://github.com/codex-storage/nim-chronos/tree/feature/profiler), [V4](https://github.com/codex-storage/nim-chronos/tree/feature/profiler-v4)) which has profiling hooks enabled.

1. [Enabling profiling]()
2. [Looking at metrics]()
2. [Enabling profiling with Prometheus metrics]()
3. [Limitations]()


## Enabling Profiling

Profiling must be enabled per event loop thread. To enable it, you need to call,
from the thread that will run your event loop:

```nim
import chroprof

enableProfiling()
``` 

## Looking at Metrics

At any time during execution, you can get a snapshot of the profiler metrics 
by calling `getMetrics()`. This will return a [`MetricsTotals`]() object which
is a table mapping [`FutureType`]()s to [`AggregateMetrics`](). You may then
print, log, or do whatever you like with those. 

`getMetrics()` will return the metrics for the event loop that is running 
(or ran) on the calling thread.

## Enabling profiling with Prometheus metrics

You can export metrics on the top-`k` async procs that are occupying the event
loop thread the most by enabling the profiler's [nim-metrics]() collector:

```nim
import chroprof/collector

# Exports metrics for the 50 heaviest procs
enableProfilerMetrics(50)
```

with the help of [Grafana](), 