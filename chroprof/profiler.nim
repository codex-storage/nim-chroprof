## This module contains the actual profiler implementation - the piece of code
## responsible for computing metrics from sequences of timestamped events and
## aggregating them.

import std/[tables, options, sets]
import chronos/[timer, srcloc]

import ./events

export timer, tables, sets, srcloc

type
  FutureType* = SrcLoc 
    ## Within the scope of the profiler, a source location identifies
    ## a future type. 

  AggregateMetrics* = object
    ## Stores aggregate metrics for a given `FutureType`.
    execTime*: Duration           ## The total time that `Future`s of a given
                                  ## `FutureType` actually ran; i.e., actively 
                                  ## occupied the event loop thread, summed 
                                  ## accross all such `Futures`.
    
    execTimeMax*: Duration        ## The maximum time that a `Future` of a
                                  ## given `FutureType` actually ran; i.e.,
                                  ## actively occupied the event loop thread.
    
    childrenExecTime*: Duration   ## Total time that the children of `Future`s
                                  ## of this `FutureType` actually ran; i.e., 
                                  ## actively occupied the event loop thread, 
                                  ## summed across all such children.
    
    wallClockTime*: Duration      ## Total time that the Future was alive; 
                                  ## i.e., the time between the Future's 
                                  ## creation and its completion, summed 
                                  ## across all runs of this `FutureType`.
                                  
    stillbornCount*: uint         ## Number of futures of this `FutureType` 
                                  ## that were born in a finished state; 
                                  ## i.e., a `FutureState` that is not Pending.
    
    callCount*: uint              ## Total number of distinct `Future`s observed
                                  ## for this `FutureType`.

  PartialMetrics = object
    state*: ExtendedFutureState
    created*: Moment
    lastStarted*: Moment
    timeToFirstPause*: Duration
    partialExecTime*: Duration
    partialChildrenExecTime*: Duration
    partialChildrenExecOverlap*: Duration
    parent*: Option[uint]
    pauses*: uint

  MetricsTotals* = Table[FutureType, AggregateMetrics]

  ProfilerState* = object
    callStack: seq[uint]
    partials: Table[uint, PartialMetrics]
    metrics*: MetricsTotals

proc `execTimeWithChildren`*(self: AggregateMetrics): Duration =
  self.execTime + self.childrenExecTime

proc push(self: var seq[uint], value: uint): void = self.add(value)

proc pop(self: var seq[uint]): uint =
  let value = self[^1]
  self.setLen(self.len - 1)
  value

proc peek(self: var seq[uint]): Option[uint] =
  if self.len == 0: none(uint) else: self[^1].some

proc `$`(location: SrcLoc): string =
  $location.procedure & "[" & $location.file & ":" & $location.line & "]"

proc futureCreated(self: var ProfilerState, event: Event): void =
  assert not self.partials.hasKey(event.futureId), $event.location

  self.partials[event.futureId] = PartialMetrics(
    created: event.timestamp,
    state: Pending,
  )

proc bindParent(self: var ProfilerState, metrics: ptr PartialMetrics): void =
  let current = self.callStack.peek()
  if current.isNone:
    return

  if metrics.parent.isSome:
    assert metrics.parent.get == current.get
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

proc futureCompleted(self: var ProfilerState, event: Event): void =
  let location = event.location
  if not self.metrics.hasKey(location):
    self.metrics[location] = AggregateMetrics()

  self.metrics.withValue(location, aggMetrics):
    if not self.partials.hasKey(event.futureId):
      # Stillborn futures are those born in a finish state. We count those cause
      # they may also be a byproduct of a bug.
      aggMetrics.stillbornCount.inc()
      return

    self.partials.withValue(event.futureId, metrics):
      if metrics.state == Running:
        self.futurePaused(event)
      
      let execTime = metrics.partialExecTime - metrics.partialChildrenExecOverlap

      aggMetrics.callCount.inc()
      aggMetrics.execTime += execTime
      aggMetrics.execTimeMax = max(aggMetrics.execTimeMax, execTime)
      aggMetrics.childrenExecTime += metrics.partialChildrenExecTime
      aggMetrics.wallClockTime += event.timestamp - metrics.created

      if metrics.parent.isSome:
        self.partials.withValue(metrics.parent.get, parentMetrics):
          parentMetrics.partialChildrenExecTime += metrics.partialExecTime
          parentMetrics.partialChildrenExecOverlap += metrics.timeToFirstPause

  self.partials.del(event.futureId)

proc processEvent*(self: var ProfilerState, event: Event): void {.nimcall, gcsafe, raises: []} =
  case event.newState:
  of Pending: self.futureCreated(event)
  of Running: self.futureRunning(event)
  of Paused: self.futurePaused(event)
  # Completion, failure and cancellation are currently handled the same way.
  of Completed: self.futureCompleted(event)
  of Failed: self.futureCompleted(event)
  of Cancelled: self.futureCompleted(event)

proc processAllEvents*(self: var ProfilerState, events: seq[Event]): void =
  for event in events:
    self.processEvent(event)