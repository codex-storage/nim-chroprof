chroprof - Profiling for [Chronos](https://github.com/status-im/nim-chronos)
============================================================================

This repo contains a usable profiler for [Chronos](https://github.com/status-im/nim-chronos). For the time being, it requires [a modified version of Chronos V4](https://github.com/codex-storage/nim-chronos/tree/feature/profiler-v4) which has profiling hooks enabled. Some of the rationale for the design and implementation of the profiler [can be found here](https://hackmd.io/eQ_ouNV4QZe0TG334_gkFg).

1. [Enabling profiling](#enabling-profiling)
2. [Looking at metrics](#looking-at-metrics)
2. [Enabling profiling with Prometheus metrics](#enabling-profiling-with-prometheus-metrics)
3. [Limitations](#limitations)


## Enabling Profiling

**Compile-time flag.** Profiling requires the `-d:chronosProfiling` compile-time
flag. If you do not pass it, importing `chroprof` will fail.

**Enabling the profiler.** The profiler must be enabled per event loop thread.
To enable it, you need to call, from the thread that will run your event loop:

```nim
import chroprof

enableProfiling()
``` 

## Looking at Metrics

At any time during execution, you can get a snapshot of the profiler metrics 
by calling `getMetrics()`. This will return a [`MetricsTotals`](https://github.com/codex-storage/nim-chroprof/blob/master/chroprof/profiler.nim#L61) object which
is a table mapping [`FutureType`](https://github.com/codex-storage/nim-chroprof/blob/master/chroprof/profiler.nim#L13)s to 
[`AggregateMetrics`](https://github.com/codex-storage/nim-chroprof/blob/master/chroprof/profiler.nim#L17). You may then 
print, log, or do whatever you like with those, including [export them to Prometheus](#enabling-profiling-with-prometheus-metrics).

`getMetrics()` will return the metrics for the event loop that is running 
(or ran) on the calling thread.

## Enabling profiling with Prometheus metrics

You can export metrics on the top-`k` async procs that are occupying the event
loop thread the most by enabling the profiler's [nim-metrics](https://github.com/status-im/nim-metrics/) collector:

```nim
import chroprof/collector

# Exports metrics for the 50 heaviest procs
enableProfilerMetrics(50)
```

with the help of [Grafana](https://grafana.com/), one can visualize and readily identify bottlenecks:

![Grafana screenshot](https://github.com/codex-storage/nim-chroprof/blob/gh-pages/assets/images/profiling-slowdown.png?raw=true)

the cumulative chart on the left shows that two procs (with the bottom one 
turning out to be a child of the top one) were dominating execution time at a 
certain point, whereas the one on the right shows a number of peaks and anomalies
which, in the context of a bug, may help identify the cause.

## Limitations

* Nested `waitFor` calls are not supported;
* Prometheus metrics only work with `refc` because nim-metrics only works with `refc`;
* the Prometheus metrics collector can only be enabled for one event loop; i.e.,
  you cannot have multiple loops in different threads publishing metrics to Prometheus.
