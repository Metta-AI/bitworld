import
  bitworld/resources

echo "Testing resource rectangle parsing"

let rects = parseResourceRects("""
/* garden */
left: 10px;
top: 20px;
width: 30px;
height: 40px;
background: #112233;

/* door */
left: 1px;
top: 2px;
width: 3px;
height: 4px;
border: rgba(10, 20, 30, 0.5);
""")

doAssert rects.len == 2, "complete rectangles should parse"
doAssert rects[0].name == "garden", "first rectangle name should parse"
doAssert rects[0].x == 10, "left should parse"
doAssert rects[0].y == 20, "top should parse"
doAssert rects[0].w == 30, "width should parse"
doAssert rects[0].h == 40, "height should parse"
doAssert rects[0].color.r == 0x11'u8, "hex red channel should parse"
doAssert rects[0].color.g == 0x22'u8, "hex green channel should parse"
doAssert rects[0].color.b == 0x33'u8, "hex blue channel should parse"
doAssert rects[0].color.a == 255'u8, "hex alpha channel should default"
doAssert rects[1].color.r == 10'u8, "rgba red channel should parse"
doAssert rects[1].color.g == 20'u8, "rgba green channel should parse"
doAssert rects[1].color.b == 30'u8, "rgba blue channel should parse"
doAssert rects[1].color.a == 128'u8, "rgba alpha channel should scale"

echo "All tests passed"
