when not defined(chronosProfiling):
  {.error: "chroprof requires -d:chronosProfiling to be enabled".}

import ./chroprof/api

export api
