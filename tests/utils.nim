import chronos
import ../chroprof/[api, events, profiler]

type
  SimpleEvent* = object
    procedure*: string
    state*: ExtendedFutureState

# XXX this is sort of bad cause we get global state all over, but the fact we
#   can't use closures on callbacks and that callbacks themselves are just
#   global vars means we can't really do much better for now.
var recording*: seq[SimpleEvent]
var rawRecording*: seq[Event]
var fakeTime*: Moment = Moment.now()

proc recordEvent(event: Event) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    recording.add(
      SimpleEvent(procedure: $event.location.procedure, state: event.newState))

    var timeShifted = event
    timeShifted.timestamp = fakeTime

    rawRecording.add(timeShifted)

proc recordSegment*(segment: string) =
  {.cast(gcsafe).}:
    recording.add(SimpleEvent(
      procedure: segment,
      state: ExtendedFutureState.Running
    ))

proc clearRecording*(): void =
  recording = @[]
  rawRecording = @[]

proc installCallbacks*() =
  assert isNil(handleFutureEvent), "There is a callback already installed"

  enableEventCallbacks(recordEvent)

proc revertCallbacks*() =
  assert not isNil(handleFutureEvent), "There are no callbacks installed"
  
  handleFutureEvent = nil

proc forProc*(self: var MetricsTotals, procedure: string): AggregateMetrics =
  for (key, aggMetrics) in self.mpairs:
    if key.procedure == procedure:
      return aggMetrics

proc resetTime*() =
  fakeTime = Moment.now()

proc advanceTime*(duration: Duration) =
  fakeTime += duration

proc advanceTimeAsync*(duration: Duration): Future[void] = 
  # Simulates a non-blocking operation that takes the provided duration to 
  # complete.
  var retFuture = newFuture[void]("advanceTimeAsync")
  var timer: TimerCallback

  proc completion(data: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      advanceTime(duration)
      retFuture.complete()

  # The actual value for the timer is irrelevant, the important thing is that 
  # this causes the parent to pause before we advance time.
  timer = setTimer(Moment.fromNow(10.milliseconds), 
    completion, cast[pointer](retFuture))

  return retFuture
