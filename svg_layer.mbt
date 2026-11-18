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
  svg_number(
    if text.has_suffix("px") {
      text[:text.length() - 2].to_owned()
    } else {
      text
    },
  )
}

///|
fn svg_dimensions(root : @dom.Element) -> (Int32, Int32) raise OraError {
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
  let (width, height) = match (root.attr("width"), root.attr("height"), view) {
    (Some(w), Some(h), _) => (svg_dimension(w), svg_dimension(h))
    (None, None, Some(size)) => size
    _ => raise Unsupported("SVG requires pixel width and height, or a viewBox")
  }
  if width <= 0.0 || height <= 0.0 || width > 2048.0 || height > 2048.0 {
    raise Unsupported(
      "SVG layer viewport must be positive and at most 2048 pixels per side",
    )
  }
  (width.ceil().to_int(), height.ceil().to_int())
}

///|
let svg_presentation_attributes : Array[String] = [
  "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
  "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
  "opacity", "color", "display", "visibility", "clip-path", "clip-rule", "stop-color",
  "stop-opacity",
]

///|
fn check_svg_paint(
  key : String,
  value : String,
  refs : Array[(String, String)],
) -> Unit raise OraError {
  let text = value[:].trim().to_owned()
  if text.to_lower().contains("url") {
    if !["fill", "stroke", "clip-path"].contains(key) ||
      !text.has_prefix("url(#") ||
      !text.has_suffix(")") ||
      text.length() <= 6 {
      raise Unsupported("SVG paint references must be local fragment IDs")
    }
    let id = text[5:text.length() - 1]
    if !id.all(c => {
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '_' ||
        c == '-' ||
        c == '.' ||
        c == ':'
      }) {
      raise Unsupported("SVG paint references must be local fragment IDs")
    }
    refs.push((key, id.to_owned()))
  }
}

///|
fn check_svg_node(
  element : @dom.Element,
  depth : Int32,
  count : Ref[Int32],
  ids : Map[String, String],
  refs : Array[(String, String)],
  in_clip : Bool,
) -> Unit raise OraError {
  count.val += 1
  if depth > 24 || count.val > 512 {
    raise Unsupported("SVG layer exceeds element or nesting limits")
  }
  let name = @dom.local_of(element.name)
  if @dom.namespace_of(element.name) is Some(uri) &&
    uri != "http://www.w3.org/2000/svg" {
    raise Unsupported("Unexpected SVG namespace")
  }
  let geometry = match name {
    "svg" if depth == 0 =>
      ["xmlns", "width", "height", "viewBox", "preserveAspectRatio", "version"]
    "g" | "defs" | "title" | "desc" => []
    "path" => ["d"]
    "rect" => ["x", "y", "width", "height", "rx", "ry"]
    "circle" => ["cx", "cy", "r"]
    "ellipse" => ["cx", "cy", "rx", "ry"]
    "line" => ["x1", "y1", "x2", "y2"]
    "polyline" | "polygon" => ["points"]
    "linearGradient" =>
      [
        "x1", "y1", "x2", "y2", "gradientUnits", "gradientTransform", "spreadMethod",
      ]
    "radialGradient" =>
      [
        "cx", "cy", "r", "fx", "fy", "gradientUnits", "gradientTransform", "spreadMethod",
      ]
    "stop" => ["offset"]
    "clipPath" => ["clipPathUnits"]
    name => raise Unsupported("Unsupported SVG element: " + name)
  }
  let in_clip = in_clip || name == "clipPath"
  if element.attr("id") is Some(id) {
    if ids.contains(id) {
      raise InvalidDocument("Duplicate SVG id: " + id)
    }
    ids[id] = name
  }
  for (key, value) in element.attrs {
    if value.length() > 8192 {
      raise Unsupported("SVG attribute exceeds size limit")
    }
    if key == "xmlns" && value != "http://www.w3.org/2000/svg" {
      raise Unsupported("Unexpected SVG namespace")
    }
    if key == "style" {
      for declaration in value.split(";") {
        let declaration = declaration.trim().to_owned()
        if declaration.is_empty() {
          continue
        }
        let pair = declaration.split(":").collect()
        if pair.length() != 2 {
          raise Unsupported("Unsupported SVG inline style declaration")
        }
        let property = pair[0].trim().to_owned()
        if !svg_presentation_attributes.contains(property) {
          raise Unsupported(
            "Unsupported SVG inline style property: " + property,
          )
        }
        if in_clip && property == "clip-path" {
          raise Unsupported("Nested SVG clipping is unsupported")
        }
        check_svg_paint(property, pair[1].to_owned(), refs)
      }
    } else if svg_presentation_attributes.contains(key) {
      if in_clip && key == "clip-path" {
        raise Unsupported("Nested SVG clipping is unsupported")
      }
      check_svg_paint(key, value, refs)
    } else if !["id", "transform"].contains(key) && !geometry.contains(key) {
      raise Unsupported("Unsupported SVG attribute: " + key)
    }
  }
  for child in element.child_elements() {
    check_svg_node(child, depth + 1, count, ids, refs, in_clip)
  }
}

///|
/// Read a self-contained static SVG. Keep its exact bytes for ORA write-back
/// and cache a transparent raster for compositing and PNG exports.
pub fn decode_svg(data : Bytes) -> Image raise {
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
  let ids : Map[String, String] = Map([])
  let refs : Array[(String, String)] = []
  check_svg_node(root, 0, Ref(0), ids, refs, false)
  for (key, id) in refs {
    let valid = if key == "clip-path" {
      ids.get(id) == Some("clipPath")
    } else {
      ids.get(id) == Some("linearGradient") ||
      ids.get(id) == Some("radialGradient")
    }
    if !valid {
      raise Unsupported("Unresolved SVG local paint reference: " + id)
    }
  }
  let (width, height) = svg_dimensions(root)
  let rendered = @vector.render_svg(
    source,
    width,
    height,
    @vector.RenderOptions::default(),
  )
  if !rendered.diagnostics.is_empty() {
    raise Unsupported("SVG renderer did not resolve all drawing instructions")
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
  { width, height, pixels, bits: 8, vector_source: Some(data), }
}
