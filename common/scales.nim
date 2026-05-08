import windy

proc displayScale*(window: Window): float32 =
  ## Returns a safe content scale for the window's current display.
  result = window.contentScale
  if result <= 0.0'f:
    result = 1.0'f

proc scaledWindowSize*(size: IVec2, scale: float32): IVec2 =
  ## Converts a logical window size to physical pixels.
  (size.vec2 * scale).ivec2
