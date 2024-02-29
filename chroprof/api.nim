import chronos/futures
import ./[profiler, events]

export Event, ExtendedFutureState, ProfilerState, MetricsTotals,
        AggregateMetrics, FutureType, execTimeWithChildren

type EventCallback* = proc (e: Event) {.nimcall, gcsafe, raises: [].}

var profilerInstance {.threadvar.}: ProfilerState

proc getMetrics*(): MetricsTotals = 
  ## Returns the `MetricsTotals` for the event loop running in the 
  ## current thread.
  result = profilerInstance.metrics

proc enableEventCallbacks*(callback: EventCallback): void =
  onBaseFutureEvent = handleBaseFutureEvent
  onAsyncFutureEvent = handleAsyncFutureEvent
  handleFutureEvent = callback
    
proc enableProfiling*(clientCallback: EventCallback = nil) =
  ## Enables profiling for the the event loop running in the current thread.
  handleFutureEvent = proc (e: Event) {.nimcall.} = 
    profilerInstance.processEvent(e)
    if not isNil(clientCallback): clientCallback(e)
