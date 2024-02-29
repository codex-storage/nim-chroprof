import math
import sequtils
import unittest2

import chronos
import chroprof/profiler

import ./utils

suite "Profiler metrics test suite":
  
    setup:
      installCallbacks()

    teardown:
      clearRecording()
      revertCallbacks()
      resetTime()

    proc recordedMetrics(): MetricsTotals = 
      var profiler: ProfilerState
      profiler.processAllEvents(rawRecording)
      profiler.metrics
  
    test "should compute correct times for a simple blocking future":
      proc simple() {.async.} =
        advanceTime(50.milliseconds)
        
      waitFor simple()

      var metrics = recordedMetrics()
      let simpleMetrics = metrics.forProc("simple")
      
      check simpleMetrics.execTime == 50.milliseconds
      check simpleMetrics.wallClockTime == 50.milliseconds

    test "should compute correct times for a simple non-blocking future":
      proc simple {.async.} =
        advanceTime(10.milliseconds)
        await advanceTimeAsync(50.milliseconds)
        advanceTime(10.milliseconds)

      waitFor simple()

      var metrics = recordedMetrics()
      let simpleMetrics = metrics.forProc("simple")

      check simpleMetrics.execTime == 20.milliseconds
      check simpleMetrics.wallClockTime == 70.milliseconds

    test "should compute correct times for a non-blocking future with multiple pauses":
      proc simple {.async.} =
        advanceTime(10.milliseconds)
        await advanceTimeAsync(50.milliseconds)
        advanceTime(10.milliseconds)
        await advanceTimeAsync(50.milliseconds)
        advanceTime(10.milliseconds)

      waitFor simple()

      var metrics = recordedMetrics()
      let simpleMetrics = metrics.forProc("simple")

      check simpleMetrics.execTime == 30.milliseconds
      check simpleMetrics.wallClockTime == 130.milliseconds

    test "should compute correct times when there is a single blocking child":
      proc child() {.async.} = 
        advanceTime(10.milliseconds)

      proc parent() {.async.} =
        advanceTime(10.milliseconds)
        await child()
        advanceTime(10.milliseconds)
        
      waitFor parent()

      var metrics = recordedMetrics()
      let parentMetrics = metrics.forProc("parent")
      let childMetrics = metrics.forProc("child")

      check parentMetrics.execTime == 20.milliseconds
      check parentMetrics.childrenExecTime == 10.milliseconds
      check parentMetrics.wallClockTime == 30.milliseconds

      check childMetrics.execTime == 10.milliseconds
      check childMetrics.wallClockTime == 10.milliseconds
      check childMetrics.childrenExecTime == ZeroDuration

    test "should compute correct times when there is a single non-blocking child":
      proc child() {.async.} =
        advanceTime(10.milliseconds)
        await advanceTimeAsync(50.milliseconds)
        advanceTime(10.milliseconds)

      proc parent() {.async.} =
        advanceTime(10.milliseconds)
        await child()
        advanceTime(10.milliseconds)

      waitFor parent()

      var metrics = recordedMetrics()
      let parentMetrics = metrics.forProc("parent")
      let childMetrics = metrics.forProc("child")

      check parentMetrics.execTime == 20.milliseconds
      check parentMetrics.childrenExecTime == 20.milliseconds
      check parentMetrics.wallClockTime == 90.milliseconds

      check childMetrics.execTime == 20.milliseconds
      check childMetrics.wallClockTime == 70.milliseconds
      check childMetrics.childrenExecTime == ZeroDuration

    test "should compute correct times when there are multiple blocking and non-blocking children":
      proc blockingChild() {.async.} = 
        advanceTime(10.milliseconds)

      proc nonblockingChild() {.async.} =
        advanceTime(10.milliseconds)
        await advanceTimeAsync(20.milliseconds)
        advanceTime(10.milliseconds)

      proc parent() {.async.} =
        advanceTime(10.milliseconds)
        await blockingChild()
        advanceTime(10.milliseconds)
        await nonblockingChild()
        advanceTime(10.milliseconds)
        await blockingChild()
        advanceTime(10.milliseconds)
        await nonblockingChild()
        advanceTime(10.milliseconds)

      waitFor parent()

      var metrics = recordedMetrics()

      let parentMetrics = metrics.forProc("parent")
      let blockingChildMetrics = metrics.forProc("blockingChild")
      let nonblockingChildMetrics = metrics.forProc("nonblockingChild")

      check parentMetrics.execTime == 50.milliseconds
      check parentMetrics.childrenExecTime == 60.milliseconds
      check parentMetrics.wallClockTime == 150.milliseconds

      check blockingChildMetrics.execTime == 20.milliseconds
      check blockingChildMetrics.wallClockTime == 20.milliseconds
      check blockingChildMetrics.childrenExecTime == ZeroDuration
      
      check nonblockingChildMetrics.execTime == 40.milliseconds
      check nonblockingChildMetrics.wallClockTime == 80.milliseconds
      check nonblockingChildMetrics.childrenExecTime == ZeroDuration

    test "should compute correct times when a child throws an exception":
      proc child() {.async: (raises: [CatchableError]).} =
        advanceTime(10.milliseconds)
        raise newException(CatchableError, "child exception")

      proc parent() {.async: (raises: [CatchableError]).} =
        advanceTime(10.milliseconds)
        try:
          await child()
        except:
          discard
        advanceTime(10.milliseconds)

      waitFor parent()

      var metrics = recordedMetrics()
      let parentMetrics = metrics.forProc("parent")
      let childMetrics = metrics.forProc("child")

      check parentMetrics.execTime == 20.milliseconds
      check parentMetrics.childrenExecTime == 10.milliseconds
      check parentMetrics.wallClockTime == 30.milliseconds

      check childMetrics.execTime == 10.milliseconds
      check childMetrics.wallClockTime == 10.milliseconds
      check childMetrics.childrenExecTime == ZeroDuration

    test "should compute correct times when a child gets cancelled":
      proc child() {.async.} =
        advanceTime(10.milliseconds)
        await sleepAsync(1.hours)

      proc parent() {.async.} =
        advanceTime(10.milliseconds)
        # This is sort of subtle: we simulate that parent runs for 10
        # milliseconds before actually cancelling the child. This renders the
        # test case less trivial as those 10 milliseconds should be billed as 
        # wallclock time at the child, causing the child's exec time and its
        # wallclock time to differ.
        let child = child()
        advanceTime(10.milliseconds)
        await child.cancelAndWait()
        advanceTime(10.milliseconds)

      waitFor parent()

      var metrics = recordedMetrics()
      let parentMetrics = metrics.forProc("parent")
      let childMetrics = metrics.forProc("child")

      check parentMetrics.execTime == 30.milliseconds
      check parentMetrics.childrenExecTime == 10.milliseconds
      check parentMetrics.wallClockTime == 40.milliseconds

      check childMetrics.execTime == 10.milliseconds
      check childMetrics.wallClockTime == 20.milliseconds
      check childMetrics.childrenExecTime == ZeroDuration

    test "should compute the correct number of times a proc gets called":
      proc child() {.async.} = discard

      proc parent() {.async.} =
        for i in 1..10:
          await child()

      waitFor parent()

      var metrics = recordedMetrics()
      let parentMetrics = metrics.forProc("parent")
      let childMetrics = metrics.forProc("child")

      check parentMetrics.callCount == 1
      check childMetrics.callCount == 10

    test "should compute the maximum execution time for a proc, out of all calls":
      var execTimes = @[10.milliseconds, 50.milliseconds, 10.milliseconds]

      proc child(d: Duration) {.async.} =
        advanceTime(d)

      proc parent() {.async.} =
        for d in execTimes:
          await child(d)

      waitFor parent()

      var metrics = recordedMetrics()
      let parentMetrics = metrics.forProc("parent")
      let childMetrics = metrics.forProc("child")

      check parentMetrics.execTimeMax == ZeroDuration
      check childMetrics.execTimeMax == 50.milliseconds

    test "should compute the correct execution time within finally blocks":
      proc withFinally() {.async.} =
        try:
          advanceTime(10.milliseconds)
          return
        finally:
          advanceTime(10.milliseconds)
          await advanceTimeAsync(10.milliseconds)
          advanceTime(10.milliseconds)

      waitFor withFinally()

      var metrics = recordedMetrics()
      var withFinallyMetrics = metrics.forProc("withFinally")

      check withFinallyMetrics.execTime == 30.milliseconds

    test "should count futures which start in a completion state":
      let completed {.used.} = Future.completed(42)
      let failed {.used.} = Future[int].failed((ref ValueError)(msg: "msg"))

      var metrics = recordedMetrics()

      let stillborns = metrics.pairs.toSeq.map(
        proc (item: (SrcLoc, AggregateMetrics)): uint =
          item[1].stillbornCount).sum

      check stillborns == 2