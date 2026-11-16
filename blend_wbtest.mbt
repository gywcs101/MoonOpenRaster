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
