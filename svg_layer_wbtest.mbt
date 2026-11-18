///|
test "SVG bounds, alpha and original source survive an ORA edit and reopen" {
  let source = b"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 2 1\"><rect width=\"1\" height=\"1\" style=\"fill:#ff0000\"/></svg>"
  let vector = decode_image(source)
  assert_eq(vector.svg_source(), Some(source))
  assert_eq(vector.pixels(), [255, 0, 0, 255, 0, 0, 0, 0])
  let base = Image::new_rgba16(3, 1, [
    10001, 20002, 30003, 65535, 10001, 20002, 30003, 65535, 10001, 20002, 30003,
    65535,
  ])
  let doc = Document::new(3, 1, [
    Layer(Properties::new("矢量"), vector),
    Layer(Properties::new("背景"), base),
  ])
  let edited = doc.set_properties(
    [0],
    Properties::new("矢量", x=1, opacity=0.5),
  )
  let reopened = read(edited.write())
  assert_eq(reopened.bit_depth(), 16)
  assert_eq(reopened.render().pixels_rgba16(), [
    10001, 20002, 30003, 65535, 37768, 10001, 15002, 65535, 10001, 20002, 30003,
    65535,
  ])
  match reopened.node([0]) {
    Layer(_, image) => assert_eq(image.svg_source(), Some(source))
    _ => fail("Expected SVG layer")
  }
  assert_eq(decode_png(reopened.layer_png([0])).pixels(), vector.pixels())
}

///|
test "transparent SVG pixels are straight alpha and viewBox scales to explicit pixels" {
  let image = decode_svg(
    b"<svg width=\"8px\" height=\"4\" viewBox=\"0 0 4 2\"><g opacity=\"0.5\"><rect x=\"1\" width=\"2\" height=\"2\" fill=\"#ff8000\"/></g></svg>",
  )
  assert_eq((image.width(), image.height()), (8, 4))
  let pixels = image.pixels()
  assert_eq(pixels[0:4].to_owned(), [0, 0, 0, 0])
  assert_eq(pixels[12:16].to_owned(), [255, 128, 0, 128])
}

///|
test "SVG source with missing resources or unsupported features is rejected" {
  for
    source in [
      b"<svg width=\"1\" height=\"1\"><image href=\"https://example.org/remote.png\"/></svg>",
      b"<svg width=\"1\" height=\"1\"><rect fill=\"url(#missing)\"/></svg>", b"<svg width=\"1\" height=\"1\"><script>anything</script></svg>",
      b"<svg width=\"1\" height=\"1\"><rect style=\"filter:url(#filter)\"/></svg>",
      b"<!DOCTYPE svg SYSTEM \"file:///external.dtd\"><svg width=\"1\" height=\"1\"/>",
      b"<svg width=\"2049\" height=\"1\"/>",
    ] {
    let result = Ok(decode_svg(source)) catch { e => Err(e) }
    assert_true(result is Err(_))
  }
}

///|
test "SVG paths can use local gradients, transforms and clips" {
  let image = decode_svg(
    b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"4\"><defs><linearGradient id=\"paint\"><stop offset=\"0%\" stop-color=\"#ff0000\"/><stop offset=\"100%\" stop-color=\"#0000ff\"/></linearGradient><clipPath id=\"bounds\"><rect x=\"1\" width=\"6\" height=\"2\"/></clipPath></defs><g clip-path=\"url(#bounds)\"><path d=\"M0 0H8V4H0Z\" transform=\"translate(1 0)\" fill=\"url(#paint)\"/></g></svg>",
  )
  let pixels = image.pixels()
  assert_eq(pixels[3], 0)
  assert_eq(pixels[19], 255)
  assert_true(pixels[4] > pixels[24])
  assert_eq(pixels[2 * 8 * 4 + 19], 0)
}
