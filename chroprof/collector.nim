## Metrics collector which allows exporting Chronos profiling metrics to 
## Prometheus.

import std/algorithm
import std/enumerate
import std/sequtils
import std/tables
import std/times

import chronos/timer
import metrics

import ./api

when defined(metrics):
  type
    ChronosProfilerInfo* = ref object of RootObj
      sampler: MetricsSampler
      sampleInterval: times.Duration
      clock: Clock
      k: int
      init: bool
      lastSample: Time
      collections*: uint

    MetricsSampler = proc (): MetricsTotals {.raises: [].}

    Clock = proc (): Time {.raises: [].}

    FutureMetrics = (FutureType, AggregateMetrics)

  const locationLabels = ["proc", "file", "line"]

  declarePublicGauge(
    chronos_exec_time_total,
    "total time in which this proc actively occupied the event loop thread",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_exec_time_with_children_total,
    "chronos_exec_time_with_children_total of this proc plus of all" & 
    "its children (procs that this proc called and awaited for)",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_wall_time_total,
    "the amount of time elapsed from when the async proc was started to when" &
    "it completed",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_call_count_total,
    "the total number of times this async proc was called and completed",
    labels = locationLabels,
  )

  # Per-proc Statistics
  declarePublicGauge(
    chronos_single_exec_time_max,
    "the maximum execution time for a single call of this proc",
    labels = locationLabels,
  )

  proc threadId(): int = 
    when defined(getThreadId):
      getThreadId()
    else:
      0

  # Keeps track of the thread initializing the module. This is the only thread
  # that will be allowed to interact with the metrics collector.
  let moduleInitThread = threadId()

  proc newCollector*(
    ChronosProfilerInfo: typedesc,
    sampler: MetricsSampler,
    clock: Clock,
    sampleInterval: times.Duration,
    k: int = 10,
  ): ChronosProfilerInfo = ChronosProfilerInfo(
    sampler: sampler,
    clock: clock,
    k: k,
    sampleInterval: sampleInterval,
    init: true,
    lastSample: low(Time),
  )

  proc collectSlowestProcs(
    self: ChronosProfilerInfo,
    profilerMetrics: seq[FutureMetrics],
    timestampMillis: int64,
    k: int,
  ): void =

    for (i, pair) in enumerate(profilerMetrics):
      if i == k:
        break

      let (location, metrics) = pair

      let locationLabels = @[
        $(location.procedure),
        $(location.file),
        $(location.line),
      ]

      chronos_exec_time_total.set(metrics.execTime.nanoseconds,
        labelValues = locationLabels)

      chronos_exec_time_with_children_total.set(
        metrics.execTimeWithChildren.nanoseconds,
        labelValues = locationLabels
      )

      chronos_wall_time_total.set(metrics.wallClockTime.nanoseconds,
        labelValues = locationLabels)

      chronos_single_exec_time_max.set(metrics.execTimeMax.nanoseconds,
        labelValues = locationLabels)

      chronos_call_count_total.set(metrics.callCount.int64,
        labelValues = locationLabels)

  proc collect*(self: ChronosProfilerInfo, force: bool = false): void =
    # Calling this method from the wrong thread has happened a lot in the past,
    # so this makes sure we're not doing anything funny.
    assert threadId() == moduleInitThread, "You cannot call collect() from" &
      " a thread other than the one that initialized the metricscolletor module"

    let now = self.clock()
    if not force and (now - self.lastSample < self.sampleInterval):
      return

    self.collections += 1
    var currentMetrics = self.
      sampler().
      pairs.
      toSeq.
      # We don't scoop metrics with 0 exec time as we have a limited number of
      # prometheus slots, and those are less likely to be useful in debugging
      # Chronos performance issues.
      filter(
        proc (pair: FutureMetrics): bool =
          pair[1].execTimeWithChildren.nanoseconds > 0
      ).
      sorted(
        proc (a, b: FutureMetrics): int =
          cmp(a[1].execTimeWithChildren, b[1].execTimeWithChildren),
        order = SortOrder.Descending
      )

    self.collectSlowestProcs(currentMetrics, now.toMilliseconds(), self.k)

    self.lastSample = now

  proc resetMetric(gauge: Gauge): void =
    # We try to be as conservative as possible and not write directly to
    # internal state. We do need to read from it, though.
    for metricSeq in gauge.metrics:
      for metric in metricSeq:
        gauge.set(0.int64, labelValues = metric.labelValues)

  proc reset*(self: ChronosProfilerInfo): void =
    resetMetric(chronos_exec_time_total)
    resetMetric(chronos_exec_time_with_children_total)
    resetMetric(chronos_wall_time_total)
    resetMetric(chronos_call_count_total)
    resetMetric(chronos_single_exec_time_max)

  var asyncProfilerInfo* {.global.}: ChronosProfilerInfo

  proc enableProfilerMetrics*(k: int) =
    assert threadId() == moduleInitThread, 
      "You cannot call enableProfilerMetrics() from a thread other than" & 
      " the one that initialized the metricscolletor module."

    asyncProfilerInfo = ChronosProfilerInfo.newCollector(
      sampler = getMetrics,
      k = k,
      # We want to collect metrics every 5 seconds.
      sampleInterval = initDuration(seconds = 5),
      clock = proc (): Time = getTime(),
    )

    enableProfiling(
      proc (e: Event) {.nimcall, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          if e.newState == ExtendedFutureState.Completed:
            asyncProfilerInfo.collect()
    )

