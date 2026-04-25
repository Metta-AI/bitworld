proc isqrt*(value: int): int =
  if value <= 0:
    return 0
  var
    x = value
    y = (x + 1) div 2
  while y < x:
    x = y
    y = (x + value div x) div 2
  x

proc ceilSqrt*(value: int): int =
  result = isqrt(value)
  if result * result < value:
    inc result

proc roundDiv*(numerator, denominator: int): int =
  if denominator <= 0:
    return 0
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc mulDivRound*(a, b, denominator: int): int =
  roundDiv(a * b, denominator)

proc scaledVector*(dx, dy, scale: int): tuple[x, y: int] =
  let distance = ceilSqrt(dx * dx + dy * dy)
  if distance <= 0:
    return (x: 0, y: 0)
  (x: mulDivRound(dx, scale, distance), y: mulDivRound(dy, scale, distance))

proc clampVectorLength*(x, y: var int, maxLength: int) =
  let lengthSq = x * x + y * y
  if lengthSq <= maxLength * maxLength:
    return
  let length = ceilSqrt(lengthSq)
  if length <= 0:
    return
  x = mulDivRound(x, maxLength, length)
  y = mulDivRound(y, maxLength, length)
