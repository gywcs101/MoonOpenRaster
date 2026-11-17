///|
test "isolated group opacity differs from per-layer opacity" {
  let red = Image::new(1, 1, [255, 0, 0, 255])
  let blue = Image::new(1, 1, [0, 0, 255, 255])
  let group = Document::new(1, 1, [
    Group(Properties::new("group", opacity=0.5), Isolate, [
      Layer(Properties::new("red"), red),
      Layer(Properties::new("blue"), blue),
    ]),
  ])
  let separate = Document::new(1, 1, [
    Layer(Properties::new("red", opacity=0.5), red),
    Layer(Properties::new("blue", opacity=0.5), blue),
  ])
  assert_eq(group.render().pixels(), [255, 0, 0, 128])
  assert_eq(separate.render().pixels()[3], 192)
}

///|
test "negative coordinates clip pixel placement" {
  let image = Image::new(2, 1, [255, 0, 0, 255, 0, 255, 0, 255])
  let doc = Document::new(1, 1, [Layer(Properties::new("offset", x=-1), image)])
  assert_eq(doc.render().pixels(), [0, 255, 0, 255])
}

///|
test "pass through opacity multiplies child opacity and ignores obsolete group offsets" {
  let image = Image::new(1, 1, [255, 0, 0, 255])
  let doc = Document::new(1, 1, [
    Group(Properties::new("auto", x=100, y=100, opacity=0.5), Auto, [
      Layer(Properties::new("red", opacity=0.5), image),
    ]),
  ])
  assert_eq(doc.render().pixels(), [255, 0, 0, 64])
}

///|
test "optimized painting agrees with pixel oracle for every operation and outside source bounds" {
  let operations = [
    "src-over", "multiply", "screen", "overlay", "darken", "lighten", "color-dodge",
    "color-burn", "hard-light", "soft-light", "difference", "hue", "saturation",
    "color", "luminosity", "plus", "dst-in", "dst-out", "src-atop", "dst-atop",
  ]
  for operation in operations {
    let op = "svg:" + operation
    for alpha in [0, 71, 255] {
      let back = [51, 102, 153, 166].map(v => v.to_double() / 255.0)
      let source = Image::new(1, 1, [204, 128, 26, alpha.to_byte()])
      let target = Image::new(3, 1, [
        51, 102, 153, 166, 51, 102, 153, 166, 51, 102, 153, 166,
      ])
      paint(target, source, 1, 0, 0.63, op)
      for x in 0..<3 {
        let front = if x == 1 {
          [
            204.0 / 255.0,
            128.0 / 255.0,
            26.0 / 255.0,
            alpha.to_double() / 255.0 * 0.63,
          ]
        } else {
          [0.0, 0.0, 0.0, 0.0]
        }
        let expected = composite_pixel(back, front, op)
        for c in 0..<4 {
          assert_eq(
            target.pixels[x * 4 + c],
            (expected[c] * 255.0 + 0.5).to_int().to_byte(),
          )
        }
      }
    }
  }
}

///|
test "Krita alpha preserve clips shading to underlying coverage" {
  let image = Image::new(2, 1, [127, 127, 127, 255, 127, 127, 127, 255])
  let base = Image::new(2, 1, [0, 0, 0, 0, 204, 128, 26, 128])
  paint(base, image, 0, 0, 0.6, "svg:hard-light", preserve_alpha=true)
  assert_eq(base.pixels()[0:4].to_owned(), [0, 0, 0, 0])
  assert_eq(base.pixels()[7], 128)
  assert_eq(base.pixels()[4:7].to_owned(), [204, 128, 26])
}
