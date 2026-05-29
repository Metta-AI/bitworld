import
  pixie,
  bitworld/sprites

proc testPixels() =
  ## Tests pixel reads, writes, and aliases.
  echo "Testing RGBA sprite pixels"
  var sprite = newRgbaSprite(3, 2)
  doAssert sprite.width == 3
  doAssert sprite.height == 2
  doAssert sprite.pixels.len == 24
  sprite.putRgbaPixel(1, 1, rgba(10, 20, 30, 40))
  doAssert sprite.rgbaSpriteAt(1, 1) == rgba(10, 20, 30, 40)
  sprite.putPixel(2, 1, rgba(1, 2, 3, 4))
  doAssert sprite.rgbaPixel(2, 1) == rgba(1, 2, 3, 4)
  sprite.putRgbaSpritePixel(-1, 0, rgba(255, 0, 0, 255))
  doAssert sprite.rgbaSpriteAt(-1, 0).a == 0

proc testCopies() =
  ## Tests pixel payload copies and comparisons.
  echo "Testing RGBA sprite pixel payloads"
  let sprite = solidRgbaSprite(2, 2, rgba(3, 4, 5, 255))
  let copy = sprite.pixels.copyPixels()
  doAssert copy.pixelsMatch(sprite.pixels)
  doAssert not copy.pixelsMatch(sprite.pixels[0 ..< sprite.pixels.len - 1])

proc testImages() =
  ## Tests Pixie image and cell conversion.
  echo "Testing RGBA sprite image conversion"
  var image = newImage(4, 4)
  image.fill(rgba(0, 0, 0, 0))
  image[2, 3] = rgba(9, 8, 7, 255)
  let sprite = image.imageRgbaSprite()
  doAssert sprite.rgbaSpriteAt(2, 3) == rgba(9, 8, 7, 255)
  image[3, 3] = rgba(1, 2, 3, 255)
  let cell = image.cellRgbaSprite(1, 1, 2)
  doAssert cell.rgbaSpriteAt(1, 1) == rgba(1, 2, 3, 255)

proc testDrawing() =
  ## Tests shape helpers.
  echo "Testing RGBA sprite drawing"
  var sprite = newRgbaSprite(8, 8)
  sprite.fillRect(1, 1, 3, 2, rgba(10, 0, 0, 255))
  doAssert sprite.rgbaSpriteAt(2, 2).a == 255
  sprite.strokeRect(0, 0, 8, 8, rgba(0, 10, 0, 255))
  doAssert sprite.rgbaSpriteAt(7, 7) == rgba(0, 10, 0, 255)
  sprite.drawLine(0, 7, 7, 0, rgba(0, 0, 10, 255))
  doAssert sprite.rgbaSpriteAt(3, 4).a == 255
  sprite.drawCircleFill(4, 4, 2, rgba(5, 6, 7, 255))
  doAssert sprite.rgbaSpriteAt(4, 4) == rgba(5, 6, 7, 255)
  sprite.drawCircleRing(4, 4, 3, 1, rgba(7, 6, 5, 255))
  doAssert sprite.rgbaSpriteAt(7, 4) == rgba(7, 6, 5, 255)

proc testBlit() =
  ## Tests alpha-blended blits.
  echo "Testing RGBA sprite blits"
  var target = solidRgbaSprite(2, 2, rgba(100, 0, 0, 255))
  let source = solidRgbaSprite(1, 1, rgba(0, 100, 0, 128))
  target.blitRgbaSprite(source, 1, 1)
  doAssert target.rgbaSpriteAt(1, 1).a == 255
  doAssert target.rgbaSpriteAt(1, 1).g > 0

proc testColor() =
  ## Tests color helpers and tinting.
  echo "Testing RGBA sprite colors"
  doAssert rgba(10, 20, 30, 255).withAlpha(7).a == 7
  doAssert rgba(100, 50, 25, 255).scaleColor(50).r == 50
  doAssert rgba(0, 0, 0, 255).mixColor(rgba(100, 50, 0, 128), 50).r == 50
  doAssert rgba(100, 100, 100, 200).stainColor(rgba(10, 20, 30, 255)).a == 200
  let tinted = solidRgbaSprite(1, 1, rgba(255, 0, 0, 255)).hsvTinted(
    0.5,
    1.0,
    1.0,
    1.0
  )
  doAssert tinted.rgbaSpriteAt(0, 0).g > 0

proc testBounds() =
  ## Tests transparent margin measurement and outlines.
  echo "Testing RGBA sprite bounds"
  var sprite = newRgbaSprite(5, 4)
  sprite.putRgbaPixel(2, 1, rgba(1, 1, 1, 255))
  sprite.putRgbaPixel(3, 2, rgba(1, 1, 1, 255))
  let
    bounds = sprite.solidBounds()
    margins = sprite.blankMargins()
    outline = sprite.outlinedSprite(rgba(255, 0, 0, 255))
  doAssert bounds.found
  doAssert bounds.minX == 2
  doAssert bounds.maxY == 2
  doAssert margins.left == 2
  doAssert margins.bottom == 1
  doAssert outline.rgbaSpriteAt(1, 1) == rgba(255, 0, 0, 255)

testPixels()
testCopies()
testImages()
testDrawing()
testBlit()
testColor()
testBounds()
echo "All tests passed"
