import ./[profiler, events]

export
  Event, ExtendedFutureState, ProfilerState, MetricsTotals, AggregateMetrics,
  FutureType, execTimeWithChildren

var profilerInstance {.threadvar.}: ProfilerState

proc getMetrics*(): MetricsTotals =
  ## Returns the `MetricsTotals` for the event loop running in the 
  ## current thread.
  result = profilerInstance.metrics

proc enableProfiling*(callback: EventCallback = nil) =
  ## Enables profiling for the the event loop running in the current thread.
  ## The client may optionally supply a callback to be notified of `Future`
  ## events.
  attachMonitoring(
    if (isNil(callback)):
      proc(e: Event) {.nimcall.} =
        profilerInstance.processEvent(e)
    else:
      proc(e: Event) {.nimcall.} =
        profilerInstance.processEvent(e)
        callback(e)
  )
