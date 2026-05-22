import
  std/unittest,
  ../../client/global_client

suite "replay controls":
  test "ui hit testing ignores transparent layer space":
    check not spriteObjectContainsPoint(
      objectX = 86,
      objectY = 8,
      spriteWidth = 84,
      spriteHeight = 5,
      pointX = 11,
      pointY = 10
    )
    check spriteObjectContainsPoint(
      objectX = 2,
      objectY = 1,
      spriteWidth = 108,
      spriteHeight = 18,
      pointX = 33,
      pointY = 10
    )
    check not spriteObjectContainsPoint(
      objectX = 2,
      objectY = 1,
      spriteWidth = 108,
      spriteHeight = 18,
      pointX = 110,
      pointY = 10
    )
