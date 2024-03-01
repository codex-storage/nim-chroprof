import ./[testevents, testprofiler]

when defined(metrics):
  import ./testmetricscollector

{.warning[UnusedImport]: off.}
