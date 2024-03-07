## This module contains the actual profiler implementation - the piece of code
## responsible for computing metrics from sequences of timestamped events and
## aggregating them.

import std/[tables, options, sets]
import chronos/[timer, srcloc]

import ./config
import ./events
import ./utils

export timer, tables, sets, srcloc

type
  FutureType* = SrcLoc
    ## Within the scope of the profiler, a source location identifies
    ## a future type. 

  AggregateMetrics* = object ## Stores aggregate metrics for a given `FutureType`.
    execTime*: Duration
      ## The total time that `Future`s of a given
      ## `FutureType` actually ran; i.e., actively 
      ## occupied the event loop thread, summed 
      ## accross all such `Futures`.

    execTimeMax*: Duration
      ## The maximum time that a `Future` of a
      ## given `FutureType` actually ran; i.e.,
      ## actively occupied the event loop thread.

    childrenExecTime*: Duration
      ## Total time that the children of `Future`s
      ## of this `FutureType` actually ran; i.e., 
      ## actively occupied the event loop thread, 
      ## summed across all such children.

    wallClockTime*: Duration
      ## Total time that the Future was alive; 
      ## i.e., the time between the Future's 
      ## creation and its completion, summed 
      ## across all runs of this `FutureType`.

    stillbornCount*: uint
      ## Number of futures of this `FutureType` 
      ## that were born in a finished state; 
      ## i.e., a `FutureState` that is not Pending.

    callCount*: uint
      ## Total number of distinct `Future`s observed
      ## for this `FutureType`.

  PartialMetrics = object
    ## Tracks `PartialMetric`s for a single run of a given `Future`. `PartialMetrics` 
    ## may not be complete until the `Future` and its children have reached a 
    ## finish state.
    created*: Moment
    lastStarted*: Moment
    timeToFirstPause*: Duration
    partialExecTime*: Duration
    partialChildrenExecTime*: Duration
    partialChildrenExecOverlap*: Duration
    wallclockTime: Duration
    pauses*: uint

    futureType: FutureType
    state*: ExtendedFutureState
    parent*: Option[uint]
    liveChildren: uint

  MetricsTotals* = Table[FutureType, AggregateMetrics]

  ProfilerState* = object
    callStack: seq[uint]
    partials: Table[uint, PartialMetrics]
    metrics*: MetricsTotals

proc `execTimeWithChildren`*(self: AggregateMetrics): Duration =
  self.execTime + self.childrenExecTime

proc futureCreated(self: var ProfilerState, event: Event): void =
  assert not self.partials.hasKey(event.futureId), $event.location

  self.partials[event.futureId] =
    PartialMetrics(created: event.timestamp, state: Pending, futureType: event.location)

proc bindParent(self: var ProfilerState, metrics: ptr PartialMetrics): void =
  let current = self.callStack.peek()
  if current.isNone:
    when chroprofDebug:
      echo "No parent for ", $metrics.futureType.procedure, ", ", $metrics.state
    return

  if metrics.parent.isSome:
    assert metrics.parent.get == current.get

  self.partials.withValue(current.get, parentMetrics):
    parentMetrics.liveChildren += 1
    when chroprofDebug:
      echo "SET_PARENT: Parent of ",
        $metrics.futureType.procedure,
        " is ",
        $parentMetrics.futureType.procedure,
        ", ",
        $metrics.state

  metrics.parent = current

proc futureRunning(self: var ProfilerState, event: Event): void =
  assert self.partials.hasKey(event.futureId), $event.location

  self.partials.withValue(event.futureId, metrics):
    assert metrics.state == Pending or metrics.state == Paused,
      $event.location & " " & $metrics.state

    self.bindParent(metrics)
    self.callStack.push(event.futureId)

    metrics.lastStarted = event.timestamp
    metrics.state = Running

proc futurePaused(self: var ProfilerState, event: Event): void =
  assert event.futureId == self.callStack.pop(), $event.location
  assert self.partials.hasKey(event.futureId), $event.location

  self.partials.withValue(event.futureId, metrics):
    assert metrics.state == Running, $event.location & " " & $metrics.state

    let segmentExecTime = event.timestamp - metrics.lastStarted

    if metrics.pauses == 0:
      metrics.timeToFirstPause = segmentExecTime
    metrics.partialExecTime += segmentExecTime
    metrics.pauses += 1
    metrics.state = Paused

proc aggregatePartial(
    self: var ProfilerState, metrics: ptr PartialMetrics, futureId: uint
): void =
  ## Aggregates partial execution metrics into the total metrics for the given
  ## `FutureType`.

  self.metrics.withValue(metrics.futureType, aggMetrics):
    let execTime = metrics.partialExecTime - metrics.partialChildrenExecOverlap

    aggMetrics.callCount.inc()
    aggMetrics.execTime += execTime
    aggMetrics.execTimeMax = max(aggMetrics.execTimeMax, execTime)
    aggMetrics.childrenExecTime += metrics.partialChildrenExecTime
    aggMetrics.wallClockTime += metrics.wallclockTime

    if metrics.parent.isSome:
      self.partials.withValue(metrics.parent.get, parentMetrics):
        when chroprofDebug:
          echo $metrics.futureType.procedure,
            ": add <<",
            metrics.timeToFirstPause,
            ">> overlap and <<",
            metrics.partialExecTime,
            ">> child exec time to parent (",
            parentMetrics.futureType.procedure,
            ")"

        parentMetrics.partialChildrenExecTime += metrics.partialExecTime
        parentMetrics.partialChildrenExecOverlap += metrics.timeToFirstPause
        parentMetrics.liveChildren -= 1

        if parentMetrics.state in FinishStates:
          if parentMetrics.liveChildren == 0:
            when chroprofDebug:
              echo "Perfom deferred aggregation of completed parent with no live children: ",
                $parentMetrics.futureType.procedure
            self.aggregatePartial(parentMetrics, metrics.parent.get)
          else:
            when chroprofDebug:
              echo "Parent ",
                $parentMetrics.futureType.procedure,
                " still has ",
                parentMetrics.liveChildren,
                " live children"

  self.partials.del(futureId)

proc countStillborn(self: var ProfilerState, futureType: FutureType): void =
  self.metrics.withValue(futureType, aggMetrics):
    aggMetrics.stillbornCount.inc()

proc futureCompleted(self: var ProfilerState, event: Event): void =
  let futureType = event.location
  let futureId = event.futureId

  if not self.metrics.hasKey(futureType):
    self.metrics[futureType] = AggregateMetrics()

  if not self.partials.hasKey(futureId):
    self.countStillborn(futureType)
    return

  self.partials.withValue(futureId, partial):
    if partial.state == Running:
      self.futurePaused(event)
      partial.state = event.newState

    partial.wallclockTime = event.timestamp - partial.created

    # Future still have live children, don't aggregate yet.
    if partial.liveChildren > 0:
      return

    self.aggregatePartial(partial, futureId)

proc processEvent*(
    self: var ProfilerState, event: Event
): void {.nimcall, gcsafe, raises: [].} =
  when chroprofDebug:
    echo "EVENT:",
      $event.location.procedure, ", ", event.newState, ", ", event.timestamp

  case event.newState
  of Pending:
    self.futureCreated(event)
  of Running:
    self.futureRunning(event)
  of Paused:
    self.futurePaused(event)
  # Completion, failure and cancellation are currently handled the same way.
  of Completed:
    self.futureCompleted(event)
  of Failed:
    self.futureCompleted(event)
  of Cancelled:
    self.futureCompleted(event)

proc processAllEvents*(self: var ProfilerState, events: seq[Event]): void =
  for event in events:
    self.processEvent(event)
