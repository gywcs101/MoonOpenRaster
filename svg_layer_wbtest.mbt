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
    if result is Ok(_) {
      fail("Unexpectedly accepted SVG: " + @utf8.decode(source[:]))
    }
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

///|
test "CSS and local reuse survive an unrelated raster-layer edit" {
  for
    markup in [
      "<style>.accent{fill:#ff0000}</style><rect class=\"accent\" width=\"1\" height=\"1\"/>",
      "<defs><rect id=\"shape\" fill=\"#ff0000\" width=\"1\" height=\"1\"/></defs><use href=\"#shape\"/>",
    ] {
    let source = @utf8.encode(
      "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\">" +
      markup +
      "</svg>",
    )
    let doc = Document::new(3, 1, [
      Layer(Properties::new("Vector"), decode_svg(source)),
      Layer(
        Properties::new("Base"),
        Image::new_rgba16(1, 1, [10001, 20002, 30003, 65535]),
      ),
    ])
    let reopened = read(
      doc.set_properties([1], Properties::new("Base", x=2)).write(),
    )
    assert_eq(reopened.render().pixels_rgba16(), [
      65535, 0, 0, 65535, 0, 0, 0, 0, 10001, 20002, 30003, 65535,
    ])
    match reopened.node([0]) {
      Layer(_, image) => assert_eq(image.svg_source(), Some(source))
      _ => fail("Expected SVG layer")
    }
  }
}

///|
test "nested SVG paths and shared PNG resources survive duplication and save" {
  let source = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"><style>@import '../styles/label.css';</style><rect class=\"label\" width=\"1\" height=\"1\"/><image href=\"../pixel.png\" x=\"1\" width=\"1\" height=\"1\"/></svg>"
  let base = Image::new(1, 1, [0, 255, 0, 255]).encode_png()
  let input = @zip.zip([
    @zip.Entry::new("mimetype", b"image/openraster", kind=Stored),
    @zip.Entry::new(
      "stack.xml",
      b"<image version=\"0.0.6\" w=\"4\" h=\"1\"><stack><layer src=\"data/art/label.svg\"/><layer src=\"data/pixel.png\"/></stack></image>",
      kind=Stored,
    ),
    @zip.Entry::new("data/art/label.svg", source, kind=Stored),
    @zip.Entry::new(
      "data/styles/label.css",
      b".label { fill: #ff0000 }",
      kind=Stored,
    ),
    @zip.Entry::new("data/pixel.png", base, kind=Stored),
  ])
  let doc = read(input)
  assert_eq(doc.layer_png([0]) |> decode_png |> Image::pixels, [
    255, 0, 0, 255, 0, 255, 0, 255,
  ])
  let saved = doc.duplicate([0], name="Copy").write()
  let entries = archive_entries(saved)
  assert_eq(resource(entries, "data/art/label.svg"), source)
  assert_eq(resource(entries, "data/pixel.png"), base)
  let reopened = read(saved)
  assert_eq(reopened.layer_png([0]), reopened.layer_png([1]))
}

///|
test "SVG mask and offset filter affect the composited pixels" {
  let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"2\"><defs><mask id=\"half\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"4\" height=\"2\"><rect width=\"1\" height=\"2\" fill=\"white\"/></mask><filter id=\"shift\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"4\" height=\"2\"><feOffset dx=\"1\" dy=\"0\"/></filter></defs><rect width=\"2\" height=\"2\" fill=\"red\" mask=\"url(#half)\"/><rect x=\"2\" width=\"1\" height=\"2\" fill=\"blue\" filter=\"url(#shift)\"/></svg>"
  assert_eq(decode_svg(svg).pixels(), [
    255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 0, 0, 255, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 255, 255,
  ])
}

///|
test "SVG cross-file vector references keep their directory after write" {
  let drawing = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"><use href=\"../shapes/symbols.svg#dot\"/></svg>"
  let symbols = b"<svg xmlns=\"http://www.w3.org/2000/svg\"><defs><rect id=\"dot\" width=\"1\" height=\"1\" fill=\"red\"/></defs></svg>"
  let input = @zip.zip(
    [
      @zip.Entry::new("mimetype", b"image/openraster", kind=Stored),
      @zip.Entry::new(
        "stack.xml",
        b"<image version=\"0.0.6\" w=\"1\" h=\"1\"><stack><layer src=\"data/art/drawing.svg\"/></stack></image>",
        kind=Stored,
      ),
      @zip.Entry::new("data/art/drawing.svg", drawing, kind=Stored),
      @zip.Entry::new("data/shapes/symbols.svg", symbols, kind=Stored),
    ][:],
  )
  let written = read(input).write()
  assert_eq(
    resource(archive_entries(written), "data/shapes/symbols.svg"),
    symbols,
  )
  assert_eq(read(written).render().pixels(), [255, 0, 0, 255])
}

///|
test "SVG physical units map to CSS pixels" {
  let image = decode_svg(
    b"<svg width=\"0.25in\" height=\"12pt\" viewBox=\"0 0 24 16\"><rect width=\"24\" height=\"16\" fill=\"red\"/></svg>",
  )
  assert_eq((image.width(), image.height()), (24, 16))
  assert_eq(image.pixels()[0:4].to_owned(), [255, 0, 0, 255])
}

///|
test "SVG pattern repeats across the composed image" {
  let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"1\"><defs><pattern id=\"tile\" patternUnits=\"userSpaceOnUse\" width=\"2\" height=\"1\"><rect width=\"1\" height=\"1\" fill=\"red\"/></pattern></defs><rect width=\"4\" height=\"1\" fill=\"url(#tile)\"/></svg>"
  assert_eq(decode_svg(svg).pixels(), [
    255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 0,
  ])
}

///|
test "text path elliptical arc has the quarter-circle length" {
  let path = @dom.Element::new("path", attrs=[
    ("d", "M10 0 a10 10 0 0 1 -10 10"),
  ])
  let paths = Map([("arc", path)])
  let run = @dom.Element::new("textPath", attrs=[
    ("href", "#arc"),
    ("startOffset", "50%"),
  ])
  let geometry = svg_text_path(run, paths)
  assert_true((geometry.length - 15.7079632679).abs() < 0.01)
  assert_true((geometry.offset - geometry.length / 2.0).abs() < 0.0000001)
  assert_true(geometry.glyph_transform(1.0, 0.0, 3.0, 0.1) is Some(_))
}

///|
test "embedded PNG image contributes its exact pixels to SVG" {
  let png = Image::new(1, 1, [125, 76, 31, 255]).encode_png()
  let reference = "data:image/png;base64," + @base64.encode(png[:])
  let svg = @utf8.encode(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\">" +
    "<image width=\"1\" height=\"1\" href=\"" +
    reference +
    "\"/></svg>",
  )
  assert_eq(decode_svg(svg).pixels(), [125, 76, 31, 255])
}

///|
test "SVG filter chain preserves named intermediate results" {
  let source = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"1\"><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"4\" height=\"1\"><feFlood flood-color=\"blue\" result=\"blue\"/><feComposite in=\"blue\" in2=\"SourceAlpha\" operator=\"in\" result=\"shape\"/><feOffset in=\"shape\" dx=\"2\" result=\"translated\"/><feMerge><feMergeNode in=\"SourceGraphic\"/><feMergeNode in=\"translated\"/></feMerge></filter></defs><rect width=\"1\" height=\"1\" fill=\"red\" filter=\"url(#f)\"/></svg>"
  assert_eq(decode_svg(source).pixels(), [
    255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0,
  ])
}

///|
test "text path uses authored pathLength for numeric distances" {
  let path = @dom.Element::new("path", attrs=[
    ("d", "M0 0 H20"),
    ("pathLength", "10"),
  ])
  let run = @dom.Element::new("textPath", attrs=[
    ("href", "#line"),
    ("startOffset", "2"),
  ])
  let geometry = svg_text_path(run, Map([("line", path)]))
  assert_eq(geometry.offset, 4.0)
  assert_eq(geometry.distance_scale, 2.0)
}

///|
test "SVG 1.1 standard doctype needs no network and keeps its source" {
  let source = b"<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\"\n \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\"><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"><rect width=\"1\" height=\"1\" fill=\"red\"/></svg>"
  let image = decode_svg(source)
  assert_eq(image.svg_source(), Some(source))
  assert_eq(image.pixels(), [255, 0, 0, 255])
}

///|
test "SVG conditional processing uses the first supported branch" {
  let source = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"><switch transform=\"translate(1 0)\"><foreignObject requiredExtensions=\"urn:unavailable\"/><rect systemLanguage=\"fr\" width=\"1\" height=\"1\" fill=\"blue\"/><rect requiredFeatures=\"http://www.w3.org/TR/SVG11/feature#Shape\" width=\"1\" height=\"1\" fill=\"red\"/><rect width=\"1\" height=\"1\" fill=\"blue\"/></switch></svg>"
  let image = decode_svg(source)
  assert_eq(image.svg_source(), Some(source))
  assert_eq(image.pixels(), [0, 0, 0, 0, 255, 0, 0, 255])
}

///|
test "SVG percentage viewport uses the containing ORA canvas" {
  let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50%\" height=\"100%\" viewBox=\"0 0 1 1\" preserveAspectRatio=\"none\"><rect width=\"1\" height=\"1\" fill=\"red\"/></svg>"
  let input = @zip.zip(
    [
      @zip.Entry::new("mimetype", b"image/openraster", kind=Stored),
      @zip.Entry::new(
        "stack.xml",
        b"<image version=\"0.0.6\" w=\"4\" h=\"2\"><stack><layer src=\"data/drawing.svg\" x=\"1\"/></stack></image>",
        kind=Stored,
      ),
      @zip.Entry::new("data/drawing.svg", svg, kind=Stored),
    ][:],
  )
  let document = read(input)
  match document.node([0]) {
    Layer(_, image) => {
      assert_eq((image.width(), image.height()), (2, 2))
      assert_eq(image.svg_source(), Some(svg))
    }
    _ => fail("Expected SVG layer")
  }
  assert_eq(document.render().pixels(), [
    0, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0,
    255, 255, 0, 0, 255, 0, 0, 0, 0,
  ])
}

///|
test "SVG text uses bundled fonts without filesystem resources" {
  let image = decode_svg(
    b"<svg xmlns='http://www.w3.org/2000/svg' width='64' height='32'><text x='2' y='24' font-size='20'>A</text><text x='32' y='24' font-size='20' font-family='serif'>B</text></svg>",
  )
  let pixels = image.pixels()
  for offset in [0, 32] {
    let mut ink = 0
    for y in 0..<32 {
      for x in offset..<(offset + 32) {
        if pixels[(y * 64 + x) * 4 + 3] > 128 {
          ink += 1
        }
      }
    }
    assert_true(ink > 20)
  }
}

///|
test "an SVG image can resolve another SVG and its own archived CSS and PNG" {
  let drawing = b"<svg xmlns='http://www.w3.org/2000/svg' width='4' height='2'><image href='../icons/tile.svg' width='2' height='2'/></svg>"
  let tile = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><style>@import './paint/theme.css';</style><rect class='mark' width='1' height='2'/><image href='./raster/pixel.png' x='1' width='1' height='2' preserveAspectRatio='none'/></svg>"
  let css = b".mark { fill: red; }"
  let pixel = Image::new(1, 1, [0, 255, 0, 255]).encode_png()
  let input = @zip.zip([
    @zip.Entry::new("mimetype", b"image/openraster", kind=Stored),
    @zip.Entry::new(
      "stack.xml",
      b"<image version='0.0.6' w='4' h='2'><stack><layer name='Vector' src='data/art/main.svg'/></stack></image>",
      kind=Stored,
    ),
    @zip.Entry::new("data/art/main.svg", drawing, kind=Stored),
    @zip.Entry::new("data/icons/tile.svg", tile, kind=Stored),
    @zip.Entry::new("data/icons/paint/theme.css", css, kind=Stored),
    @zip.Entry::new("data/icons/raster/pixel.png", pixel, kind=Stored),
  ])
  let saved = read(input)
    .set_properties([0], Properties::new("Vector", x=1))
    .write()
  let entries = archive_entries(saved)
  assert_eq(resource(entries, "data/art/main.svg"), drawing)
  assert_eq(resource(entries, "data/icons/tile.svg"), tile)
  assert_eq(resource(entries, "data/icons/paint/theme.css"), css)
  assert_eq(resource(entries, "data/icons/raster/pixel.png"), pixel)
  assert_eq(read(saved).render().pixels(), [
    0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0,
    255, 0, 255, 0, 255, 0, 0, 0, 0,
  ])
}

///|
test "recursive SVG images fail without silently dropping the nested layer" {
  let first = b"<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'><image href='two.svg' width='1' height='1'/></svg>"
  let second = b"<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'><image href='./one.svg' width='1' height='1'/></svg>"
  let input = @zip.zip([
    @zip.Entry::new("mimetype", b"image/openraster", kind=Stored),
    @zip.Entry::new(
      "stack.xml",
      b"<image w='1' h='1'><stack><layer name='Cycle' src='data/one.svg'/></stack></image>",
      kind=Stored,
    ),
    @zip.Entry::new("data/one.svg", first, kind=Stored),
    @zip.Entry::new("data/two.svg", second, kind=Stored),
  ])
  let result = Ok(read(input)) catch { error => Err(error) }
  match result {
    Err(Unsupported(message)) =>
      assert_eq(
        message, "data/one.svg: SVG rendering failed for resource: two.svg",
      )
    Err(error) => fail("Unexpected failure: " + error.to_string())
    Ok(_) => fail("An SVG resource cycle must report a failure")
  }
}

///|
test "embedded SVG image data goes through the bounded SVG renderer" {
  let child = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1'><rect width='1' height='1' fill='red'/></svg>"
  let encoded = @base64.encode(child[:])
  let inline_text = "%3Csvg%20xmlns='http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg'%20width='2'%20height='1'%3E%3Crect%20width='1'%20height='1'%20fill='red'%2F%3E%3C%2Fsvg%3E"
  for
    uri in [
      "data:image/svg+xml;base64," + encoded,
      "data:image/svg+xml," + inline_text,
    ] {
    let root = @utf8.encode(
      "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"><image width=\"2\" height=\"1\" href=\"" +
      uri +
      "\"/></svg>",
    )
    let image = decode_svg(root)
    assert_eq(image.pixels(), [255, 0, 0, 255, 0, 0, 0, 0])
    assert_eq(image.svg_source(), Some(root))
  }
}
