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

///|
test "16-bit painting agrees with every operation and keeps low channel bits" {
  let operations = [
    "src-over", "multiply", "screen", "overlay", "darken", "lighten", "color-dodge",
    "color-burn", "hard-light", "soft-light", "difference", "hue", "saturation",
    "color", "luminosity", "plus", "dst-in", "dst-out", "src-atop", "dst-atop",
  ]
  for operation in operations {
    let source = Image::new_rgba16(1, 1, [52361, 31983, 6667, 45901])
    let target = Image::new_rgba16(1, 1, [13048, 26221, 39313, 42800])
    let front = [
      52361.0 / 65535.0,
      31983.0 / 65535.0,
      6667.0 / 65535.0,
      45901.0 / 65535.0 * 0.63,
    ]
    let back = [
      13048.0 / 65535.0,
      26221.0 / 65535.0,
      39313.0 / 65535.0,
      42800.0 / 65535.0,
    ]
    let op = "svg:" + operation
    paint(target, source, 0, 0, 0.63, op)
    let samples = target.pixels_rgba16()
    let expected = composite_pixel(back, front, op)
    for i in 0..<4 {
      assert_true(
        (samples[i] - (expected[i] * 65535.0 + 0.5).to_int()).abs() <= 1,
      )
    }
  }
}

///|
test "mixed bit depth keeps hidden source precision and promotes 8-bit channels exactly" {
  let source = [10001, 20002, 30003, 40004]
  let wide = Image::new_rgba16(1, 1, source)
  source[0] = 1
  let returned = wide.pixels_rgba16()
  returned[1] = 2
  assert_eq(wide.pixels_rgba16(), [10001, 20002, 30003, 40004])
  let doc = Document::new(2, 1, [
    Group(Properties::new("isolated"), Isolate, [
      Layer(Properties::new("wide", x=1), wide),
      Layer(Properties::new("narrow"), Image::new(1, 1, [3, 7, 251, 255])),
    ]),
  ])
  let reopened = read(doc.write())
  assert_eq(reopened.bit_depth(), 16)
  assert_eq(reopened.render().pixels_rgba16(), [
    771, 1799, 64507, 65535, 10001, 20002, 30003, 40004,
  ])
  assert_eq(decode_png(reopened.layer_png([0, 1])).bit_depth(), 8)
  assert_eq(decode_png(reopened.layer_png([0, 0])).bit_depth(), 16)
}
