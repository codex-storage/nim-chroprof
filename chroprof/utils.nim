import std/options
import chronos/srcloc

proc push*(self: var seq[uint], value: uint): void =
  self.add(value)

proc pop*(self: var seq[uint]): uint =
  let value = self[^1]
  self.setLen(self.len - 1)
  value

proc peek*(self: var seq[uint]): Option[uint] =
  if self.len == 0:
    none(uint)
  else:
    self[^1].some

proc `$`*(location: SrcLoc): string =
  $location.procedure & "[" & $location.file & ":" & $location.line & "]"
