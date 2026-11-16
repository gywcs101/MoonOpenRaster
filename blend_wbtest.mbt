///|
test "source over independent premultiplied expectation" {
  let p = composite_pixel(
    [0.0, 0.0, 1.0, 1.0],
    [1.0, 0.0, 0.0, 0.5],
    "svg:src-over",
  )
  assert_eq(p, [0.5, 0.0, 0.5, 1.0])
}

///|
test "porter duff destination operations" {
  assert_eq(
    composite_pixel([1.0, 0.0, 0.0, 0.5], [0.0, 1.0, 0.0, 0.25], "svg:dst-in"),
    [1.0, 0.0, 0.0, 0.125],
  )
  assert_eq(
    composite_pixel([1.0, 0.0, 0.0, 0.5], [0.0, 1.0, 0.0, 0.25], "svg:dst-out"),
    [1.0, 0.0, 0.0, 0.375],
  )
}

///|
test "blend mode analytical endpoints" {
  let modes = [
    "svg:src-over", "svg:multiply", "svg:screen", "svg:overlay", "svg:darken", "svg:lighten",
    "svg:color-dodge", "svg:color-burn", "svg:hard-light", "svg:soft-light", "svg:difference",
    "svg:color", "svg:luminosity", "svg:hue", "svg:saturation", "svg:plus", "svg:dst-in",
    "svg:dst-out", "svg:src-atop", "svg:dst-atop",
  ]
  for mode in modes {
    let p = composite_pixel([0.3, 0.6, 0.2, 0.0], [0.4, 0.5, 0.8, 0.0], mode)
    assert_eq(p, [0.0, 0.0, 0.0, 0.0])
  }
  assert_eq(channel(0.25, 0.5, "svg:multiply"), 0.125)
  assert_eq(channel(0.25, 0.5, "svg:screen"), 0.625)
  assert_eq(channel(0.25, 0.5, "svg:overlay"), 0.25)
}

///|
/// Numerical vectors derived directly from the W3C opaque blending definitions.
test "opaque separable modes match analytical reference values" {
  let fixtures : Array[(String, Double)] = [
    ("svg:src-over", 0.8),
    ("svg:multiply", 0.2),
    ("svg:screen", 0.85),
    ("svg:overlay", 0.4),
    ("svg:darken", 0.25),
    ("svg:lighten", 0.8),
    ("svg:color-dodge", 1.0),
    ("svg:color-burn", 0.0625),
    ("svg:hard-light", 0.7),
    ("svg:soft-light", 0.4),
    ("svg:difference", 0.55),
  ]
  for (op, expected) in fixtures {
    let out = composite_pixel([0.25, 0.25, 0.25, 1.0], [0.8, 0.8, 0.8, 1.0], op)
    assert_true((out[0] - expected).abs() < 0.000000001)
    assert_eq(out[3], 1.0)
  }
}

///|
test "nonseparable modes preserve defining luminosity and saturation" {
  let b = [0.2, 0.4, 0.6, 1.0]
  let s = [0.8, 0.5, 0.1, 1.0]
  for op in ["svg:hue", "svg:saturation", "svg:color"] {
    let out = composite_pixel(b, s, op)
    assert_true((lum(out) - 0.362).abs() < 0.000000001)
  }
  let hue = composite_pixel(b, s, "svg:hue")
  assert_true((sat(hue) - 0.4).abs() < 0.000000001)
  let saturation = composite_pixel(b, s, "svg:saturation")
  assert_true((sat(saturation) - 0.7).abs() < 0.000000001)
  let l = composite_pixel(b, s, "svg:luminosity")
  assert_true((l[0] - 0.384).abs() < 0.000000001)
  assert_true((l[1] - 0.584).abs() < 0.000000001)
  assert_true((l[2] - 0.784).abs() < 0.000000001)
}

///|
test "atop and additive operations have independent fractional-alpha vectors" {
  assert_eq(
    composite_pixel([1.0, 0.0, 0.0, 0.5], [0.0, 1.0, 0.0, 0.25], "svg:src-atop"),
    [0.75, 0.25, 0.0, 0.5],
  )
  assert_eq(
    composite_pixel([1.0, 0.0, 0.0, 0.5], [0.0, 1.0, 0.0, 0.25], "svg:dst-atop"),
    [0.5, 0.5, 0.0, 0.25],
  )
  let plus = composite_pixel(
    [1.0, 0.0, 0.0, 0.5],
    [0.0, 1.0, 0.0, 0.25],
    "svg:plus",
  )
  assert_true((plus[0] - 2.0 / 3.0).abs() < 0.000000001)
  assert_true((plus[1] - 1.0 / 3.0).abs() < 0.000000001)
  assert_eq(plus[3], 0.75)
}
