import ./[profiler, events]

export
  Event, ExtendedFutureState, ProfilerState, MetricsTotals, AggregateMetrics,
  FutureType, execTimeWithChildren

var profilerInstance {.threadvar.}: ProfilerState

proc getMetrics*(): MetricsTotals =
  ## Returns the `MetricsTotals` for the event loop running in the 
  ## current thread.
  result = profilerInstance.metrics

template enableProfiling*(callback: EventCallback) =
  ## Enables profiling for the the event loop running in the current thread.
  ## The client may optionally supply a callback to be notified of `Future`
  ## events.
  attachMonitoring(
      proc(e: Event) {.nimcall, gcsafe, raises: [].} =
        profilerInstance.processEvent(e)
        callback(e)
  )

template enableProfiling*() =
  attachMonitoring(
    proc(e: Event) {.nimcall, gcsafe, raises: [].} =
      profilerInstance.processEvent(e)
  )
