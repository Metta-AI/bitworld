import windy

const
  MaxUiZoom* = 3
  MaxUiZoomFitPadding* = 1.5'f

proc displayScale*(window: Window): float32 =
  ## Returns a safe content scale for the window's current display.
  result = window.contentScale
  if result <= 0.0'f:
    result = 1.0'f

proc scaledWindowSize*(size: IVec2, scale: float32): IVec2 =
  ## Converts a logical window size to physical pixels.
  (size.vec2 * scale).ivec2

proc uiLayerZoom*(
  viewW, viewH: float32,
  layerWidth, layerHeight: int
): int =
  ## Returns the largest integer UI zoom that still fits one layer.
  let
    width = max(1, layerWidth).float32
    height = max(1, layerHeight).float32
    fit = min(viewW / width, viewH / height)
  result = 1
  for scale in countdown(MaxUiZoom, 2):
    if fit >= scale.float32 * MaxUiZoomFitPadding:
      return scale

proc uiZoomForLayers*(
  viewW, viewH: float32,
  layerSizes: openArray[tuple[width, height: int]]
): float32 =
  ## Returns the smallest integer UI zoom that fits every layer.
  result = MaxUiZoom.float32
  if layerSizes.len == 0:
    return
  for layer in layerSizes:
    result = min(
      result,
      uiLayerZoom(viewW, viewH, layer.width, layer.height).float32
    )
