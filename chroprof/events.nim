## This module provides the callbacks that hook into Chronos and record 
## timestamped events on Future state transitions. It also consolidates 
## the FutureState and AsyncFutureState into a single enum to ease downstream
## processing.
## 
## This is an internal module and none of what is here should be considered API.

import chronos/[timer, futures, srcloc]

type
  ExtendedFutureState* {.pure.} = enum
    Pending
    Running
    Paused
    Completed
    Cancelled
    Failed

  Event* = object ## A timestamped event transition in a `Future` state.
    future: FutureBase
    newState*: ExtendedFutureState
    timestamp*: Moment

  EventCallback* = proc(e: Event) {.nimcall, gcsafe, raises: [].}

const FinishStates* = [
  ExtendedFutureState.Completed, ExtendedFutureState.Cancelled,
  ExtendedFutureState.Failed,
]

var handleFutureEvent {.threadvar.}: EventCallback

proc `location`*(self: Event): SrcLoc =
  self.future.internalLocation[Create][]

proc `futureId`*(self: Event): uint =
  self.future.id

proc mkEvent(future: FutureBase, state: ExtendedFutureState): Event =
  Event(future: future, newState: state, timestamp: Moment.now())

proc handleBaseFutureEvent*(future: FutureBase, state: FutureState): void {.nimcall.} =
  {.cast(gcsafe).}:
    let extendedState =
      case state
      of FutureState.Pending: ExtendedFutureState.Pending
      of FutureState.Completed: ExtendedFutureState.Completed
      of FutureState.Cancelled: ExtendedFutureState.Cancelled
      of FutureState.Failed: ExtendedFutureState.Failed

    if not isNil(handleFutureEvent):
      handleFutureEvent(mkEvent(future, extendedState))

proc handleAsyncFutureEvent*(
    future: FutureBase, state: AsyncFutureState
): void {.nimcall.} =
  {.cast(gcsafe).}:
    let extendedState =
      case state
      of AsyncFutureState.Running: ExtendedFutureState.Running
      of AsyncFutureState.Paused: ExtendedFutureState.Paused

    if not isNil(handleFutureEvent):
      handleFutureEvent(mkEvent(future, extendedState))

proc attachMonitoring*(callback: EventCallback) =
  ## Enables monitoring of Chronos `Future` state transitions on the
  ## event loop that runs in the current thread. The provided callback will be
  ## called at every such event.
  onBaseFutureEvent = handleBaseFutureEvent
  onAsyncFutureEvent = handleAsyncFutureEvent
  handleFutureEvent = callback

proc detachMonitoring*() =
  onBaseFutureEvent = nil
  onAsyncFutureEvent = nil
  handleFutureEvent = nil
