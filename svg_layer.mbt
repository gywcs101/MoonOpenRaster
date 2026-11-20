///|
fn looks_like_svg_xml(data : BytesView) -> Bool {
  let mut start = if data.has_prefix(b"\xef\xbb\xbf"[:]) { 3 } else { 0 }
  while start < data.length() &&
        [b'\x20', b'\t', b'\r', b'\n'].contains(data[start]) {
    start += 1
  }
  start < data.length() && data[start] == b'<'
}

///|
fn svg_number(value : String) -> Double raise OraError {
  // SVG accepts +1, .5 and 1. in addition to JSON's number syntax.
  let stripped = value[:].trim().to_owned()
  let s = if stripped.has_prefix("+") {
    stripped[1:].to_owned()
  } else {
    stripped
  }
  let s = if s.has_prefix(".") {
    "0" + s
  } else if s.has_prefix("-.") {
    "-0" + s[1:].to_owned()
  } else {
    s
  }
  let s = if s.has_suffix(".") { s + "0" } else { s }
  let n = parse_number(s) catch {
    _ => raise Unsupported("Unsupported SVG dimension or viewBox number")
  }
  if n.is_nan() || n.abs() > 1000000.0 {
    raise InvalidDocument("SVG dimension or viewBox is out of range")
  }
  n
}

///|
fn svg_dimension(value : String) -> Double raise OraError {
  let text = value[:].trim().to_owned()
  for
    (unit, factor) in [
      ("px", 1.0),
      ("in", 96.0),
      ("cm", 96.0 / 2.54),
      ("mm", 96.0 / 25.4),
      ("pt", 96.0 / 72.0),
      ("pc", 16.0),
    ] {
    if text.has_suffix(unit) {
      return svg_number(text[:text.length() - unit.length()].to_owned()) *
        factor
    }
  }
  svg_number(text)
}

///|
fn svg_dimensions(
  root : @dom.Element,
  viewport : (Int32, Int32)?,
) -> (Int32, Int32) raise OraError {
  let view = match root.attr("viewBox") {
    Some(value) => {
      let separated = value
        .replace_all(old=",", new=" ")
        .replace_all(old="\t", new=" ")
        .replace_all(old="\r", new=" ")
        .replace_all(old="\n", new=" ")
      let parts : Array[String] = []
      for token in separated.split(" ") {
        if !token.is_empty() {
          parts.push(token.to_owned())
        }
      }
      if parts.length() != 4 {
        raise Unsupported("SVG viewBox must contain four numbers")
      }
      ignore(svg_number(parts[0]))
      ignore(svg_number(parts[1]))
      let w = svg_number(parts[2])
      let h = svg_number(parts[3])
      if w <= 0.0 || h <= 0.0 {
        raise InvalidDocument("SVG viewBox dimensions must be positive")
      }
      Some((w, h))
    }
    None => None
  }
  let (container_w, container_h) = match viewport {
    Some((w, h)) => (w.to_double(), h.to_double())
    None => view.unwrap_or((300.0, 150.0))
  }
  fn axis(value : String?, fallback : Double) -> Double raise OraError {
    guard value is Some(text) else { return fallback }
    let text = text[:].trim().to_owned()
    if text.has_suffix("%") {
      fallback * svg_number(text[:text.length() - 1].to_owned()) / 100.0
    } else {
      svg_dimension(text)
    }
  }
  let w = root.attr("width")
  let h = root.attr("height")
  let (width, height) = if w is None && h is None && view is Some(size) {
    size
  } else {
    (axis(w, container_w), axis(h, container_h))
  }
  if width <= 0.0 || height <= 0.0 || width > 2048.0 || height > 2048.0 {
    raise Unsupported(
      "SVG layer viewport must be positive and at most 2048 pixels per side",
    )
  }
  (width.ceil().to_int(), height.ceil().to_int())
}

///|
fn check_svg_node(
  element : @dom.Element,
  depth : Int32,
  count : Ref[Int32],
  ids : Map[String, Bool],
  refs : Array[String],
) -> Unit raise OraError {
  count.val += 1
  if depth > 24 || count.val > 512 {
    raise Unsupported("SVG layer exceeds element or nesting limits")
  }
  let name = @dom.local_of(element.name)
  if @dom.namespace_of(element.name) is Some(uri) &&
    uri != "http://www.w3.org/2000/svg" {
    return
  }
  if ![
      "svg", "g", "defs", "title", "desc", "metadata", "path", "rect", "circle",
      "ellipse", "line", "polyline", "polygon", "linearGradient", "radialGradient",
      "stop", "clipPath", "style", "text", "tspan", "textPath", "symbol", "use",
      "image", "mask", "pattern", "marker", "filter", "feBlend", "feColorMatrix",
      "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting",
      "feDisplacementMap", "feDistantLight", "feFlood", "feFuncA", "feFuncB", "feFuncG",
      "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology",
      "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile",
      "feTurbulence",
    ].contains(name) {
    raise Unsupported("Unsupported SVG element: " + name)
  }
  if element.attr("id") is Some(id) {
    if ids.contains(id) {
      raise InvalidDocument("Duplicate SVG id: " + id)
    }
    ids[id] = true
  }
  for (key, value) in element.attrs {
    if value.length() > 8192 &&
      !(name == "image" &&
      (key == "href" || key == "{http://www.w3.org/1999/xlink}href") &&
      value.has_prefix("data:image/")) {
      raise Unsupported("SVG attribute exceeds size limit")
    }
    if key == "href" || key == "xlink:href" {
      let href = value[:].trim().to_owned()
      if href.has_prefix("#") {
        refs.push(href[1:].to_owned())
      } else if href.has_prefix("/") ||
        (href.contains(":") && !href.has_prefix("data:")) {
        raise Unsupported("SVG reference is outside the archive: " + href)
      }
    }
    let mut rest = value
    while rest.find("url(#") is Some(index) {
      rest = rest[index + 5:].to_owned()
      guard rest.find(")") is Some(end) else { break }
      refs.push(rest[:end].to_owned())
      rest = rest[end + 1:].to_owned()
    }
    if key.to_lower().has_prefix("on") {
      raise Unsupported("SVG event handlers are unsupported")
    }
  }
  for child in element.child_elements() {
    check_svg_node(child, depth + 1, count, ids, refs)
  }
}

///|
fn svg_hex_digit(byte : Byte) -> Int32 {
  let value = byte.to_int()
  if value >= 48 && value <= 57 {
    value - 48
  } else if value >= 65 && value <= 70 {
    value - 55
  } else if value >= 97 && value <= 102 {
    value - 87
  } else {
    -1
  }
}

///|
fn svg_unescape_path(path : String) -> String? {
  let bytes = @utf8.encode(path)
  let output : Array[Byte] = []
  let mut cursor = 0
  while cursor < bytes.length() {
    if bytes[cursor] == b'%' {
      guard cursor + 2 < bytes.length() else { return None }
      let hi = svg_hex_digit(bytes[cursor + 1])
      let lo = svg_hex_digit(bytes[cursor + 2])
      guard hi >= 0 && lo >= 0 else { return None }
      let byte = (hi * 16 + lo).to_byte()
      guard byte != b'/' && byte != b'\\' && byte != b'\x00' else {
        return None
      }
      output.push(byte)
      cursor += 3
    } else {
      output.push(bytes[cursor])
      cursor += 1
    }
  }
  Some(@utf8.decode(Bytes::from_array(output)[:])) catch {
    _ => None
  }
}

///|
fn svg_archive_path(base : String, href : String) -> String? {
  let uri = href[:].trim().to_owned()
  let absolute = uri.has_prefix("ora:/") && !uri.has_prefix("ora://")
  let encoded = if absolute { uri[5:].to_owned() } else { uri }
  guard svg_unescape_path(encoded) is Some(path) else { return None }
  if path == "" ||
    path.has_prefix("/") ||
    path.contains(":") ||
    path.contains("\\") ||
    path.contains("?") ||
    path.contains("#") {
    return None
  }
  let segments : Array[String] = []
  if !absolute {
    for part in base.split("/") {
      segments.push(part.to_owned())
    }
    ignore(segments.pop())
  }
  for part in path.split("/") {
    match part.to_owned() {
      "" | "." => ()
      ".." => if segments.pop() is None { return None }
      item => segments.push(item)
    }
  }
  Some(segments.join("/"))
}

///|
fn svg_archive_uri(path : String) -> String {
  "ora:/" + path.replace_all(old="%", new="%25")
}

///|
fn svg_archive_resource(
  path : String,
  entries : Array[(String, Bytes)],
  retained : Map[String, Bool],
  href : String,
) -> Bytes? {
  guard svg_archive_path(path, href) is Some(name) else { return None }
  let data = resource(entries, name) catch { _ => return None }
  retained[name] = true
  Some(data)
}

///|
fn svg_resource_options(
  path : String,
  entries : Array[(String, Bytes)],
  retained : Map[String, Bool],
) -> @vector.RenderOptions {
  let options = @vector.RenderOptions::default()
  let load = href => svg_archive_resource(path, entries, retained, href)
  let images : Map[String, @vector.Image] = Map([])
  let used_pixels = Ref(0L)
  {
    ..options,
    environment: { ..options.environment, base_uri: svg_archive_uri(path), },
    text_resource_resolver: Some(fn(href, kind) {
      guard svg_archive_path(path, href) is Some(name) &&
        load(href) is Some(data) &&
        data.length() <= 262144 else {
        return None
      }
      let resolve_related = reference => {
        svg_archive_resource(name, entries, retained, reference)
      }
      Some(
        match kind {
          Stylesheet => @utf8.decode(data[:])
          SvgDocument => {
            let (source, root) = svg_parse_source(data)
            svg_render_source(source, root, name, resolve_related)
          }
        },
      ) catch {
        _ => None
      }
    }),
    image_resolver: Some(fn(href) {
      if images.get(href) is Some(image) {
        return Some(image)
      }
      let payload = if href.has_prefix("data:") {
        guard href.find(",") is Some(comma) else { return None }
        let media_type = href[:comma].to_owned().to_lower()
        guard ["data:image/png;base64", "data:image/jpeg;base64"].contains(
          media_type,
        ) else {
          return None
        }
        Some(@base64.decode(href[comma + 1:].to_owned())) catch {
          _ => None
        }
      } else {
        load(href)
      }
      guard payload is Some(data) &&
        (
          data[:].has_prefix(b"\x89PNG\r\n\x1a\n"[:]) ||
          data[:].has_prefix(b"\xff\xd8"[:])
        ) else {
        return None
      }
      let source = decode_image(data) catch { _ => return None }
      used_pixels.val += source.width.to_int64() * source.height.to_int64()
      guard used_pixels.val <= 4194304L else { return None }
      let pixels = source.pixels()
      let image = @vector.Image::new(source.width, source.height)
      for y in 0..<source.height {
        for x in 0..<source.width {
          let i = (y * source.width + x) * 4
          image.set_pixel(
            x,
            y,
            @vector.Color::rgba(
              pixels[i].to_int(),
              pixels[i + 1].to_int(),
              pixels[i + 2].to_int(),
              pixels[i + 3].to_int(),
            ),
          )
        }
      }
      images[href] = image
      Some(image)
    }),
  }
}

///|
/// Read a self-contained static SVG. Keep its exact bytes for ORA write-back
/// and cache a transparent raster for compositing and PNG exports.
pub fn decode_svg(data : Bytes) -> Image raise {
  let options = svg_resource_options("", [], Map([]))
  decode_svg_with_options(data, options, None, _ => None)
}

///|
fn svg_branch_matches(element : @dom.Element) -> Bool {
  if !element.attr("requiredExtensions").unwrap_or("").is_empty() {
    return false
  }
  if element.attr("systemLanguage") is Some(languages) {
    // Keep CLI, library and offline workbench deterministic.
    if !languages
      .split(",")
      .any(value => {
        let language = value.trim().to_owned().to_lower()
        language == "en"
      }) {
      return false
    }
  }
  let features = element
    .attr("requiredFeatures")
    .unwrap_or("")
    .replace_all(old="\t", new=" ")
    .replace_all(old="\r", new=" ")
    .replace_all(old="\n", new=" ")
  features
  .split(" ")
  .all(feature => {
    if feature.is_empty() {
      return true
    }
    let prefix = "http://www.w3.org/TR/SVG11/feature#"
    feature.has_prefix(prefix) &&
    [
      "CoreAttribute", "BasicStructure", "Structure", "ContainerAttribute", "ConditionalProcessing",
      "Shape", "OpacityAttribute", "Gradient",
    ].contains(feature[prefix.length():].to_owned())
  })
}

///|
fn svg_select_branches(
  element : @dom.Element,
  depth : Int32,
  count : Ref[Int32],
) -> Bool raise OraError {
  count.val += 1
  if depth > 24 || count.val > 512 {
    raise Unsupported("SVG layer exceeds element or nesting limits")
  }
  let mut changed = false
  for child in element.child_elements() {
    if !svg_branch_matches(child) {
      ignore(child.remove())
      changed = true
    } else if @dom.local_of(child.name) == "switch" {
      let children : Array[@dom.Node] = []
      for candidate in child.child_elements() {
        if svg_branch_matches(candidate) {
          children.push(ElementNode(candidate))
          break
        }
      }
      let group = @dom.Element::new("g", attrs=child.attrs, children~)
      ignore(svg_select_branches(group, depth + 1, count))
      ignore(child.replace_with(ElementNode(group)))
      changed = true
    } else if svg_select_branches(child, depth + 1, count) {
      changed = true
    }
  }
  changed
}

///|
fn svg_parse_source(data : Bytes) -> (String, @dom.Element) raise {
  if data.length() > 262144 {
    raise Unsupported("SVG layer exceeds 256 KiB")
  }
  let bytes = data[:]
  let source = @utf8.decode(
    if bytes.has_prefix(b"\xef\xbb\xbf"[:]) {
      bytes[3:]
    } else {
      bytes
    },
  )
  let source = match source.find("<!DOCTYPE") {
    None => source
    Some(start) => {
      guard source[start:].find(">") is Some(length) else {
        raise InvalidDocument("Truncated SVG document type")
      }
      let end = start + length + 1
      let declaration = source[start:end]
        .to_owned()
        .replace_all(old="\r", new=" ")
        .replace_all(old="\n", new=" ")
        .replace_all(old="\t", new=" ")
        .replace_all(old="'", new="\"")
      let words : Array[String] = []
      for word in declaration.split(" ") {
        if !word.is_empty() {
          words.push(word.to_owned())
        }
      }
      guard [
        "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">",
        "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.0//EN\" \"http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd\">",
      ].contains(words.join(" ")) else {
        raise Unsupported("Unsupported SVG document type")
      }
      // The well-known declaration contributes no external entity content.
      source[:start].to_owned() + source[end:].to_owned()
    }
  }
  let lower = source.to_lower()
  if lower.contains("<!doctype") ||
    lower.contains("<!entity") ||
    lower.contains("<?xml-stylesheet") {
    raise Unsupported(
      "SVG document declarations and external stylesheets are unsupported",
    )
  }
  let parsed = @xml.loads(source)
  guard parsed.document_element() is Some(root) &&
    @dom.local_of(root.name) == "svg" else {
    raise Unsupported("Expected an SVG root element")
  }
  let changed = svg_select_branches(root, 0, Ref(0))
  let ids : Map[String, Bool] = Map([])
  let refs : Array[String] = []
  check_svg_node(root, 0, Ref(0), ids, refs)
  for id in refs {
    if !ids.contains(id) {
      raise Unsupported("Unresolved SVG local reference: " + id)
    }
  }
  (if changed { @dom.dumps(ElementNode(root)) } else { source }, root)
}

///|
fn svg_render_source(
  source : String,
  root : @dom.Element,
  path : String,
  font_resource : (String) -> Bytes?,
) -> String raise {
  if outline_svg_text(root, path, font_resource) {
    @dom.dumps(ElementNode(root))
  } else {
    source
  }
}

///|
fn decode_svg_with_options(
  data : Bytes,
  options : @vector.RenderOptions,
  path : String?,
  font_resource : (String) -> Bytes?,
  viewport~ : (Int32, Int32)? = None,
) -> Image raise {
  let (source, root) = svg_parse_source(data)
  let (width, height) = svg_dimensions(root, viewport)
  let render_source = svg_render_source(
    source,
    root,
    path.unwrap_or(""),
    font_resource,
  )
  let rendered = @vector.render_svg(render_source, width, height, options)
  for diagnostic in rendered.diagnostics {
    raise Unsupported(
      "SVG rendering failed for resource: " + diagnostic.resource,
    )
  }
  let pixels : Array[Byte] = Array::make(width * height * 4, 0)
  for y in 0..<height {
    for x in 0..<width {
      let color = rendered.image.get_pixel(x, y)
      let i = (y * width + x) * 4
      pixels[i] = color.r.to_byte()
      pixels[i + 1] = color.g.to_byte()
      pixels[i + 2] = color.b.to_byte()
      pixels[i + 3] = color.a.to_byte()
    }
  }
  {
    width,
    height,
    pixels,
    bits: 8,
    vector_source: Some(data),
    vector_path: path,
    raster_source: None,
  }
}
