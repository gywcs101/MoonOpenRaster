///|
fn looks_like_svg_xml(data : BytesView) -> Bool {
  if data.has_prefix(b"\xff\xfe"[:]) || data.has_prefix(b"\xfe\xff"[:]) {
    return true
  }
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
fn svg_viewbox_size(root : @dom.Element) -> (Double, Double)? raise OraError {
  match root.attr("viewBox") {
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
}

///|
fn svg_viewport_axis(
  value : String?,
  fallback : Double,
) -> Double raise OraError {
  guard value is Some(text) else { return fallback }
  let text = text[:].trim().to_owned()
  if text.has_suffix("%") {
    fallback * svg_number(text[:text.length() - 1].to_owned()) / 100.0
  } else {
    svg_dimension(text)
  }
}

///|
fn svg_dimensions(
  root : @dom.Element,
  viewport : (Int32, Int32)?,
) -> (Int32, Int32) raise OraError {
  let view = svg_viewbox_size(root)
  let (container_w, container_h) = match viewport {
    Some((w, h)) => (w.to_double(), h.to_double())
    None => view.unwrap_or((300.0, 150.0))
  }
  let w = root.attr("width")
  let h = root.attr("height")
  let (width, height) = if w is None && h is None && view is Some(size) {
    size
  } else {
    (svg_viewport_axis(w, container_w), svg_viewport_axis(h, container_h))
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
      "svg", "g", "a", "switch", "defs", "title", "desc", "metadata", "path", "rect",
      "circle", "ellipse", "line", "polyline", "polygon", "linearGradient", "radialGradient",
      "stop", "clipPath", "style", "text", "tspan", "tref", "textPath", "symbol",
      "use", "image", "view", "mask", "pattern", "marker", "filter", "feBlend", "feColorMatrix",
      "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting",
      "feDisplacementMap", "feDistantLight", "feFlood", "feFuncA", "feFuncB", "feFuncG",
      "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology",
      "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile",
      "feTurbulence", "font", "font-face", "font-face-src", "font-face-name", "glyph",
      "missing-glyph", "hkern", "vkern",
    ].contains(name) {
    raise Unsupported("Unsupported SVG element: " + name)
  }
  if element.attr("id") is Some(id) {
    if ids.contains(id) {
      raise InvalidDocument("Duplicate SVG id: " + id)
    }
    ids[id] = true
  }
  if ["title", "desc", "metadata"].contains(name) {
    return
  }
  for (key, value) in element.attrs {
    if value.length() > 8192 &&
      !(name == "image" &&
      (key == "href" || key == "{http://www.w3.org/1999/xlink}href") &&
      value.has_prefix("data:image/")) {
      raise Unsupported("SVG attribute exceeds size limit")
    }
    // A hyperlink is preserved as source. It does not load a rendering resource.
    if name != "a" &&
      (key == "href" || key == "{http://www.w3.org/1999/xlink}href") {
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
fn svg_unescape(value : String, path~ : Bool) -> String? {
  let bytes = @utf8.encode(value)
  let output : Array[Byte] = []
  let mut cursor = 0
  while cursor < bytes.length() {
    if bytes[cursor] == b'%' {
      guard cursor + 2 < bytes.length() else { return None }
      let hi = svg_hex_digit(bytes[cursor + 1])
      let lo = svg_hex_digit(bytes[cursor + 2])
      guard hi >= 0 && lo >= 0 else { return None }
      let byte = (hi * 16 + lo).to_byte()
      guard byte != b'\x00' && (!path || (byte != b'/' && byte != b'\\')) else {
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
  guard svg_unescape(encoded, path=true) is Some(path) else { return None }
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
priv struct SvgImageResources {
  images : Map[String, @vector.Image]
  active : Map[String, Bool]
  used_pixels : Ref[Int64]
}

///|
fn SvgImageResources::reserve(
  self : SvgImageResources,
  width : Int32,
  height : Int32,
) -> Bool {
  let area = width.to_int64() * height.to_int64()
  if self.used_pixels.val + area > 4194304L {
    return false
  }
  self.used_pixels.val += area
  true
}

///|
fn svg_raster_resource(
  data : Bytes,
  state : SvgImageResources,
) -> @vector.Image? {
  guard data[:].has_prefix(b"\x89PNG\r\n\x1a\n"[:]) ||
    data[:].has_prefix(b"\xff\xd8"[:]) else {
    return None
  }
  let source = decode_image(data) catch { _ => return None }
  guard state.reserve(source.width, source.height) else { return None }
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
  Some(image)
}

///|
fn svg_inline_image(href : String) -> Bytes? {
  guard href.find(",") is Some(comma) else { return None }
  let media = href[:comma].to_owned().to_lower()
  let mime = if media.has_prefix("ora-inline-image:") {
    media[17:].to_owned()
  } else {
    media[5:].to_owned()
  }
  guard svg_unescape(href[comma + 1:].to_owned(), path=false) is Some(content) else {
    return None
  }
  if ["image/png;base64", "image/jpeg;base64"].contains(mime) ||
    (mime.has_prefix("image/svg+xml;") && mime.has_suffix(";base64")) {
    Some(@base64.decode(content[:], ignore_whitespace=true)) catch {
      _ => None
    }
  } else if mime == "image/svg+xml" || mime == "image/svg+xml;charset=utf-8" {
    Some(@utf8.encode(content))
  } else {
    None
  }
}

///|
fn svg_resource_options(
  path : String,
  entries : Array[(String, Bytes)],
  retained : Map[String, Bool],
  images~ : SvgImageResources = {
    images: Map([]),
    active: Map([]),
    used_pixels: Ref(0L),
  },
) -> @vector.RenderOptions {
  let options = @vector.RenderOptions::default()
  let load = href => svg_archive_resource(path, entries, retained, href)
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
      let inline_svg = href.has_prefix("ora-inline-image:")
      let inline = href.has_prefix("data:") || inline_svg
      let (location, fragment) = match href.find("#") {
        Some(at) if !inline =>
          (href[:at].to_owned(), Some(href[at + 1:].to_owned()))
        _ => (href, None)
      }
      let name = if inline_svg {
        path + "\u0000" + location
      } else if inline {
        location
      } else {
        guard svg_archive_path(path, location) is Some(name) else {
          return None
        }
        name
      }
      let key = match fragment {
        Some(value) => name + "#" + value
        None => name
      }
      if images.images.get(key) is Some(image) {
        return Some(image)
      }
      guard !images.active.contains(name) && images.active.length() < 8 else {
        return None
      }
      let payload = if inline {
        svg_inline_image(location)
      } else {
        load(location)
      }
      guard payload is Some(data) else { return None }
      let image = if (!inline || inline_svg) && looks_like_svg_xml(data[:]) {
        images.active[name] = true
        let base = if inline_svg { path } else { name }
        let result = svg_nested_image(
          data, base, entries, retained, images, fragment,
        ) catch {
          _ => None
        }
        ignore(images.active.remove(name))
        result
      } else if fragment is None {
        svg_raster_resource(data, images)
      } else {
        None
      }
      if image is Some(decoded) {
        images.images[key] = decoded
      }
      image
    }),
  }
}

///|
fn svg_apply_image_view(root : @dom.Element, fragment : String) -> Unit raise {
  guard svg_unescape(fragment, path=false) is Some(view) else {
    raise Unsupported("Invalid SVG image view fragment")
  }
  if view.has_prefix("svgView(") && view.has_suffix(")") {
    let applied : Map[String, Bool] = Map([])
    for spec in view[8:view.length() - 1].split(";") {
      guard spec.find("(") is Some(open) && spec.has_suffix(")") else {
        raise Unsupported("Invalid SVG image view parameter")
      }
      let name = spec[:open].to_owned()
      guard !applied.contains(name) &&
        ["viewBox", "preserveAspectRatio"].contains(name) else {
        raise Unsupported("Unsupported SVG image view parameter: " + name)
      }
      root.set_attr(name, spec[open + 1:spec.length() - 1].to_owned())
      applied[name] = true
    }
  } else {
    fn lookup(element : @dom.Element, in_root : Bool) -> @dom.Element? {
      if element.attr("id") == Some(view) &&
        @dom.local_of(element.name) == "view" &&
        in_root {
        return Some(element)
      }
      for child in element.child_elements() {
        let in_root = in_root && @dom.local_of(child.name) != "svg"
        if lookup(child, in_root) is Some(found) {
          return Some(found)
        }
      }
      None
    }
    guard lookup(root, true) is Some(target) else {
      raise Unsupported("Unresolved SVG image view: " + view)
    }
    for name in ["viewBox", "preserveAspectRatio"] {
      if target.attr(name) is Some(value) {
        root.set_attr(name, value)
      }
    }
  }
  ignore(svg_viewbox_size(root))
}

///|
fn svg_nested_image(
  data : Bytes,
  name : String,
  entries : Array[(String, Bytes)],
  retained : Map[String, Bool],
  images : SvgImageResources,
  fragment : String?,
) -> @vector.Image? raise {
  let (source, root) = svg_parse_source(data)
  let source = match fragment {
    Some(fragment) => {
      svg_apply_image_view(root, fragment)
      @dom.dumps(ElementNode(root))
    }
    None => source
  }
  let (width, height) = svg_dimensions(root, None)
  guard images.reserve(width, height) else { return None }
  let prepared = svg_render_source(
    source,
    root,
    name,
    href => svg_archive_resource(name, entries, retained, href),
    size=Some((width, height)),
  )
  let options = svg_resource_options(name, entries, retained, images~)
  let rendered = @vector.render_svg(prepared, width, height, options)
  guard rendered.diagnostics.is_empty() else { return None }
  Some(rendered.image)
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
  let single_branch = @dom.local_of(element.name) == "switch"
  let mut emitted = false
  for child in element.child_elements() {
    if (single_branch && emitted) || !svg_branch_matches(child) {
      ignore(child.remove())
      changed = true
    } else {
      emitted = true
      if svg_select_branches(child, depth + 1, count) {
        changed = true
      }
    }
  }
  changed
}

///|
fn svg_project_stylesheets(
  document : @dom.Document,
  root : @dom.Element,
) -> Bool raise {
  let styles : Array[@dom.Node] = []
  for node in document.children().items {
    match node {
      ProcessingInstructionNode(instruction) if instruction.target ==
        "xml-stylesheet" => {
        let parameters = @xml.loads("<stylesheet " + instruction.data + "/>")
        guard parameters.document_element() is Some(attributes) &&
          attributes.attr("href") is Some(href) &&
          attributes.attr("type").unwrap_or("text/css") == "text/css" else {
          raise Unsupported("SVG stylesheet must reference CSS")
        }
        if attributes.attr("alternate").unwrap_or("no") == "yes" {
          continue
        }
        let media = attributes.attr("media").unwrap_or("all")
        guard !href.is_empty() &&
          !href.contains("\\") &&
          !href.contains("\"") &&
          !href.contains("\n") &&
          !href.contains("\r") &&
          media.all(c => (c >= 'a' && c <= 'z') || c == ',' || c == ' ') else {
          raise Unsupported("Unsupported SVG stylesheet URL or media")
        }
        let css = "@import url(\"" + href + "\") " + media + ";"
        styles.push(
          ElementNode(@dom.Element::new("style", children=[TextNode(css)])),
        )
      }
      _ => ()
    }
  }
  for index in 0..<styles.length() {
    root.insert(index, styles[index])
  }
  !styles.is_empty()
}

///|
fn svg_decode_utf16(bytes : BytesView, endian : @utf16.Endian) -> String raise {
  let text = @utf16.decode(bytes, endianness=endian, ignore_bom=true)
  if !text.has_prefix("<?xml") ||
    text.length() <= 5 ||
    ![' ', '\t', '\n', '\r'].any(space => text[5].to_int() == space.to_int()) {
    return text
  }
  guard text.find("?>") is Some(end) else {
    raise InvalidDocument("Truncated SVG XML declaration")
  }
  let declaration = text[5:end].to_owned()
  let attributes = @xml.loads("<declaration " + declaration + "/>")
  guard attributes.document_element() is Some(element) &&
    element.attr("encoding") is Some(encoding) else {
    return text
  }
  let expected = if endian is Little { "utf-16le" } else { "utf-16be" }
  guard encoding.to_lower() == "utf-16" || encoding.to_lower() == expected else {
    raise InvalidDocument("SVG XML encoding disagrees with its byte order mark")
  }
  "<?xml" +
  declaration.replace_all(old=encoding, new="UTF-8") +
  text[end:].to_owned()
}

///|
fn svg_parse_source(data : Bytes) -> (String, @dom.Element) raise {
  if data.length() > 262144 {
    raise Unsupported("SVG layer exceeds 256 KiB")
  }
  let bytes = data[:]
  let source = if bytes.has_prefix(b"\xff\xfe"[:]) {
    svg_decode_utf16(bytes, Little)
  } else if bytes.has_prefix(b"\xfe\xff"[:]) {
    svg_decode_utf16(bytes, Big)
  } else {
    @utf8.decode(
      if bytes.has_prefix(b"\xef\xbb\xbf"[:]) {
        bytes[3:]
      } else {
        bytes
      },
    )
  }
  let parsed = @xml.loads(source, limit=32, entity_limit=65536)
  if !parsed.unresolved().is_empty() {
    raise Unsupported(
      "SVG uses unresolved XML entities: " + parsed.unresolved().join(", "),
    )
  }
  let mut contains_doctype = false
  for node in parsed.children().items {
    if node is DoctypeNode(declaration) {
      contains_doctype = true
      // MoonXML expands internal entity declarations without accessing external resources.
      let header = match declaration.find("[") {
        Some(at) => declaration[:at].to_owned()
        None => declaration
      }
      let normalized = header
        .replace_all(old="\r", new=" ")
        .replace_all(old="\n", new=" ")
        .replace_all(old="\t", new=" ")
        .replace_all(old="'", new="\"")
      let words : Array[String] = []
      for word in normalized.split(" ") {
        if !word.is_empty() {
          words.push(word.to_owned())
        }
      }
      guard [
        "svg", "svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\"",
        "svg PUBLIC \"-//W3C//DTD SVG 1.0//EN\" \"http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd\"",
      ].contains(words.join(" ")) else {
        raise Unsupported("Unsupported SVG document type")
      }
    }
  }
  guard parsed.document_element() is Some(root) &&
    @dom.local_of(root.name) == "svg" else {
    raise Unsupported("Expected an SVG root element")
  }
  let styles = svg_project_stylesheets(parsed, root)
  let changed = svg_select_branches(root, 0, Ref(0)) ||
    styles ||
    contains_doctype
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
  size~ : (Int32, Int32)? = None,
) -> String raise {
  let mut normalized = false
  let mut references_text = false
  let fonts : Array[@dom.Element] = []
  fn normalize(element : @dom.Element) -> Unit {
    if @dom.local_of(element.name) == "tref" {
      references_text = true
    }
    if ["image", "feImage"].contains(@dom.local_of(element.name)) {
      for key in ["href", "{http://www.w3.org/1999/xlink}href"] {
        if element.attr(key) is Some(href) {
          let uri = href[:].trim().to_owned()
          if uri.to_lower().has_prefix("data:image/svg+xml") {
            // Resolve the child with the same safe parser and resource budget.
            // Keep the input URI unchanged in the stored layer source.
            element.set_attr(key, "ora-inline-image:" + uri[5:].to_owned())
            normalized = true
          }
        }
      }
    }
    for child in element.child_elements() {
      if ["title", "desc", "metadata"].contains(@dom.local_of(child.name)) {
        ignore(child.remove())
        normalized = true
      } else {
        if @dom.local_of(child.name) == "font" {
          fonts.push(child)
        }
        normalize(child)
      }
    }
  }
  normalize(root)
  if references_text {
    ignore(expand_svg_text_references(root, path, font_resource))
    normalized = true
  }
  let outlined = outline_svg_text(root, path, font_resource, size)
  for font in fonts {
    ignore(font.remove())
  }
  if outlined || normalized || !fonts.is_empty() {
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
    size=Some((width, height)),
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
