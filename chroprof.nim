when not defined(chronosProfiling):
  {.error: "chronprof requires -d:chronosProfiling to be enabled".}

import ./chroprof/api

export api