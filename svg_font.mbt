///|
fn svg_css_unquote(value : String) -> String {
  let trimmed = value[:].trim().to_owned()
  if trimmed.length() >= 2 &&
    (
      (trimmed.has_prefix("'") && trimmed.has_suffix("'")) ||
      (trimmed.has_prefix("\"") && trimmed.has_suffix("\""))
    ) {
    return trimmed[1:trimmed.length() - 1].to_owned()
  }
  trimmed
}

///|
fn svg_css_properties(source : String) -> Map[String, String] {
  let properties : Map[String, String] = Map([])
  let mut start = 0
  let mut depth = 0
  let mut quote = 0
  for index in 0..<=source.length() {
    let token = if index == source.length() {
      59
    } else {
      source[index].to_int()
    }
    if quote != 0 {
      if token == quote {
        quote = 0
      }
    } else if token == 34 || token == 39 {
      quote = token
    } else if token == 40 {
      depth += 1
    } else if token == 41 {
      depth -= 1
    } else if token == 59 && depth == 0 {
      let declaration = source[start:index]
      if declaration.find(":") is Some(colon) {
        let key = declaration[:colon].trim().to_owned().to_lower()
        properties[key] = declaration[colon + 1:].trim().to_owned()
      }
      start = index + 1
    }
  }
  properties
}

///|
priv struct SvgFontFace {
  sources : Array[String]
  embedded : SvgInlineFont?
  weight : Int32
  font_style : String
}

///|
fn svg_font_sources(declaration : String, base : String) -> Array[String] {
  let urls : Array[String] = []
  let mut quote = 0
  let mut depth = 0
  let mut argument : Int32? = None
  for i in 0..<declaration.length() {
    let character = declaration[i].to_int()
    if quote != 0 {
      if character == quote {
        quote = 0
      }
    } else if character == 34 || character == 39 {
      quote = character
    } else if character == 40 {
      if depth == 0 &&
        i >= 3 &&
        declaration[i - 3:i].to_owned().to_lower() == "url" {
        argument = Some(i + 1)
      }
      depth += 1
    } else if character == 41 && depth > 0 {
      depth -= 1
      if depth == 0 && argument is Some(start) {
        let href = svg_css_unquote(declaration[start:i].to_owned())
        if href.has_prefix("data:") {
          urls.push(href)
        } else if href.find("#") is Some(fragment) {
          let location = href[:fragment].to_owned()
          if location.to_lower().has_suffix(".svg") &&
            svg_archive_path(base, location) is Some(path) {
            urls.push(svg_archive_uri(path) + href[fragment:].to_owned())
          }
        } else if svg_archive_path(base, href) is Some(path) {
          urls.push(svg_archive_uri(path))
        }
        argument = None
      }
    }
  }
  urls
}

///|
fn svg_font_weight(value : String, default~ : Int32 = 400) -> Int32 {
  match value {
    "normal" => 400
    "bold" => 700
    _ => {
      let number = svg_number(value) catch { _ => default.to_double() }
      if number >= 1.0 && number <= 1000.0 {
        number.to_int()
      } else {
        default
      }
    }
  }
}

///|
fn svg_font_weight_rank(weight : Int32, desired : Int32) -> Int32 {
  if desired < 400 {
    if weight <= desired {
      desired - weight
    } else {
      1000 + weight - desired
    }
  } else if desired > 500 {
    if weight >= desired {
      weight - desired
    } else {
      1000 + desired - weight
    }
  } else if weight >= desired && weight <= 500 {
    weight - desired
  } else if weight < desired {
    1000 + desired - weight
  } else {
    2000 + weight - desired
  }
}

///|
fn svg_font_style_rank(font_style : String, desired : String) -> Int32 {
  if font_style == desired {
    0
  } else if font_style != "normal" && desired != "normal" {
    1
  } else {
    2
  }
}

///|
fn svg_font_faces_from_css(
  source : String,
  base : String,
  faces : Map[String, Array[SvgFontFace]],
  sheets : Array[@css.Stylesheet],
  visited : Map[String, Bool],
  load : (String) -> Bytes?,
  depth : Int32,
) -> Unit raise {
  let sheet = @css.parse_stylesheet(source)
  for imported in sheet.imports {
    if imported.media != "" && imported.media != "all" {
      continue
    }
    guard svg_archive_path(base, imported.href) is Some(path) else { continue }
    let uri = svg_archive_uri(path)
    if visited.contains(uri) {
      continue
    }
    if depth >= 8 || visited.length() >= 32 {
      raise Unsupported("SVG font stylesheet dependency limit exceeded")
    }
    let bytes = match load(uri) {
      Some(bytes) => bytes
      None => continue
    }
    if bytes.length() > 262144 {
      raise Unsupported("SVG font stylesheet exceeds 256 KiB: " + path)
    }
    visited[uri] = true
    svg_font_faces_from_css(
      @utf8.decode(bytes[:]),
      path,
      faces,
      sheets,
      visited,
      load,
      depth + 1,
    )
  }
  sheets.push(sheet)
  let mut css = source
  while css.find("@font-face") is Some(index) {
    css = css[index + 10:].to_owned()
    guard css.find("{") is Some(begin) else { break }
    guard css[begin + 1:].find("}") is Some(body_length) else { break }
    let end = begin + 1 + body_length
    let properties = svg_css_properties(css[begin + 1:end].to_owned())
    css = css[end + 1:].to_owned()
    if properties.get("font-family") is Some(family) &&
      properties.get("src") is Some(source) {
      let sources = svg_font_sources(source, base)
      if !sources.is_empty() {
        let name = svg_css_unquote(family).to_lower()
        let variants = faces.get(name).unwrap_or([])
        variants.push({
          sources,
          embedded: None,
          weight: svg_font_weight(
            properties.get("font-weight").unwrap_or("normal"),
          ),
          font_style: properties.get("font-style").unwrap_or("normal"),
        })
        faces[name] = variants
      }
    }
  }
}

///|
fn svg_text_selector(
  element : @dom.Element,
  parent : @css.Element?,
) -> @css.Element {
  let mut selector = @css.Element::new(@dom.local_of(element.name))
  for (key, value) in element.attrs {
    selector = selector.set_attribute(key, value)
  }
  if element.attr("id") is Some(id) {
    selector = selector.set_id(id)
  }
  for class in element.classes() {
    selector = selector.add_class(class)
  }
  if parent is Some(parent) {
    selector = selector.set_parent(parent)
  }
  selector
}

///|
fn svg_text_cascade(
  element : @dom.Element,
  selector : @css.Element,
  sheets : Array[@css.Stylesheet],
) -> @css.CascadedValues {
  let inline : Array[@css.Declaration] = []
  for key, value in svg_css_properties(element.attr("style").unwrap_or("")) {
    let important = value.to_lower().has_suffix("!important")
    let declared = if important {
      value[:value.length() - 10].trim().to_owned()
    } else {
      value
    }
    inline.push(
      @css.Declaration::from_inline(
        key,
        declared,
        if important {
          Important
        } else {
          Normal
        },
      ),
    )
  }
  @css.cascade_element(selector, sheets, inline)
}

///|
fn svg_relative_length(value : String, font_size : Double) -> Double raise {
  let value = value[:].trim().to_owned()
  if value.has_suffix("em") {
    svg_number(value[:value.length() - 2].to_owned()) * font_size
  } else if value.has_suffix("ex") {
    svg_number(value[:value.length() - 2].to_owned()) * font_size * 0.5
  } else {
    svg_dimension(value)
  }
}

///|
fn svg_resolve_font_size(value : String, inherited : Double) -> Double raise {
  match value {
    "xx-small" => 9.0
    "x-small" => 10.0
    "small" => 13.0
    "medium" => 16.0
    "large" => 18.0
    "x-large" => 24.0
    "xx-large" => 32.0
    "larger" => inherited * 1.2
    "smaller" => inherited / 1.2
    "inherit" => inherited
    raw if raw.has_suffix("%") =>
      svg_number(raw[:raw.length() - 1].to_owned()) * inherited / 100.0
    _ => svg_relative_length(value, inherited)
  }
}

///|
fn svg_text_properties(
  element : @dom.Element,
  inherited : Map[String, String],
  computed : @css.CascadedValues,
) -> Map[String, String] {
  let properties = inherited.copy()
  if element.attr("{http://www.w3.org/XML/1998/namespace}lang")
    is Some(language) {
    properties["language"] = language
  }
  for
    name in [
      "font-family", "font-size", "font-weight", "font-style", "text-anchor", "letter-spacing",
      "word-spacing", "direction", "writing-mode", "glyph-orientation-vertical",
    ] {
    let candidate = match computed.get(name) {
      Some(declaration) =>
        match declaration.value {
          Value(value) => Some(value)
          Initial => {
            ignore(properties.remove(name))
            None
          }
          _ => None
        }
      None => element.attr(name)
    }
    if candidate is Some(value) {
      properties[name] = if name == "font-size" {
        let size = svg_dimension(properties.get(name).unwrap_or("16")) catch {
          _ => 16.0
        }
        let resolved = svg_resolve_font_size(value, size) catch { _ => size }
        if resolved >= 0.0 {
          resolved.to_string()
        } else {
          size.to_string()
        }
      } else if name == "font-weight" &&
        (value == "lighter" || value == "bolder") {
        let parent = svg_font_weight(properties.get(name).unwrap_or("normal"))
        (if value == "lighter" {
          if parent < 550 {
            100
          } else if parent < 750 {
            400
          } else {
            700
          }
        } else if parent < 350 {
          400
        } else if parent < 550 {
          700
        } else {
          900
        }).to_string()
      } else {
        value
      }
    }
  }
  properties
}

///|
fn svg_load_font(uri : String, load : (String) -> Bytes?) -> Bytes? {
  if !uri.has_prefix("data:") {
    return load(uri)
  }
  guard uri.find(",") is Some(comma) else { return None }
  let media_type = uri[:comma].to_owned().to_lower()
  guard media_type.has_suffix(";base64") &&
    (
      media_type.has_prefix("data:font/") ||
      media_type.has_prefix("data:application/font-") ||
      media_type == "data:application/octet-stream;base64"
    ) else {
    return None
  }
  Some(@base64.decode(uri[comma + 1:].to_owned())) catch {
    _ => None
  }
}

///|
fn svg_font_directory_is_bounded(data : BytesView) -> Bool {
  let limit = data.length().to_int64()
  guard limit >= 12L && limit <= 8388608L else { return false }
  // Check sizes before handing the font to the OpenType reader.
  fn number(offset : Int32, count : Int32) -> Int64 {
    let mut value = 0L
    for i in offset..<(offset + count) {
      value = value * 256L + data[i].to_int().to_int64()
    }
    value
  }
  if data[:4] == b"wOFF"[:] || data[:4] == b"wOF2"[:] {
    let woff2 = data[:4] == b"wOF2"[:]
    let minimum = if woff2 { 48 } else { 44 }
    guard data.length() >= minimum &&
      number(8, 4) == limit &&
      number(16, 4) <= 8388608L else {
      return false
    }
    let count = number(12, 2).to_int()
    guard count > 0 && count <= 256 else { return false }
    if !woff2 {
      guard minimum + 20 * count <= data.length() else { return false }
      for i in 0..<count {
        let at = minimum + i * 20
        let start = number(at + 4, 4)
        let compressed = number(at + 8, 4)
        let original = number(at + 12, 4)
        guard compressed <= original &&
          original <= 8388608L &&
          start + compressed <= limit else {
          return false
        }
      }
      return true
    }
    let mut at = minimum
    fn read_length() -> Bool {
      let mut value = 0L
      for _ in 0..<5 {
        guard at < data.length() else { return false }
        let byte = data[at].to_int()
        at += 1
        value = value * 128L + (byte & 127).to_int64()
        guard value <= 8388608L else { return false }
        if byte < 128 {
          return true
        }
      }
      false
    }
    for _ in 0..<count {
      guard at < data.length() else { return false }
      let flags = data[at].to_int()
      let tag = flags & 63
      let version = flags >> 6
      at += 1
      let mut glyph_table = tag == 10 || tag == 11
      if tag == 63 {
        guard data.length() - at >= 4 else { return false }
        glyph_table = data[at:at + 4] == b"glyf"[:] ||
          data[at:at + 4] == b"loca"[:]
        at += 4
      }
      let transformed = if glyph_table { version == 0 } else { version != 0 }
      guard read_length() && (!transformed || read_length()) else {
        return false
      }
    }
    return at.to_int64() + number(20, 4) <= limit
  }
  let start = if data[:4] == b"ttcf"[:] {
    guard limit >= 16L && number(8, 4) > 0L else { return false }
    number(12, 4)
  } else {
    0L
  }
  guard start + 12L <= limit else { return false }
  let at = start.to_int()
  guard [b"\x00\x01\x00\x00", b"OTTO", b"true"].any(magic => {
    data[at:at + 4] == magic[:]
  }) else {
    return false
  }
  let count = number(at + 4, 2).to_int()
  guard count > 0 && count <= 256 && at + 12 + count * 16 <= data.length() else {
    return false
  }
  for i in 0..<count {
    let record = at + 12 + i * 16
    guard number(record + 8, 4) + number(record + 12, 4) <= limit else {
      return false
    }
  }
  true
}

///|
fn svg_text_numbers(
  element : @dom.Element,
  name : String,
  size : Double,
  axis : Double,
) -> Array[Double] raise {
  let value = element
    .attr(name)
    .unwrap_or("")
    .replace_all(old=",", new=" ")
    .replace_all(old="\t", new=" ")
    .replace_all(old="\r", new=" ")
    .replace_all(old="\n", new=" ")
  let result : Array[Double] = []
  for item in value.split(" ") {
    if !item.is_empty() {
      let token = item.to_owned()
      if name == "rotate" {
        result.push(svg_number(token))
      } else if token.has_suffix("%") {
        result.push(svg_viewport_axis(Some(token), axis))
      } else {
        result.push(svg_relative_length(token, size))
      }
    }
  }
  result
}

///|
fn svg_unpositioned_spans(element : @dom.Element) -> Bool {
  element
  .child_elements()
  .all(child => {
    ["tspan", "tref", "a"].contains(@dom.local_of(child.name)) &&
    !["x", "y", "dx", "dy", "rotate", "transform"].any(key => {
      child.has_attr(key)
    }) &&
    svg_unpositioned_spans(child)
  })
}

///|
fn svg_spacing(value : String?, size : Double) -> Double raise {
  match value {
    None | Some("normal") => 0.0
    Some(raw) => svg_relative_length(raw, size)
  }
}

///|
fn svg_shape_font_sources(
  family : String,
  sources : Array[String],
  fonts : Map[String, @font.TTFont],
  load : (String) -> Bytes?,
  text : String,
  size : Double,
  desired_weight : Int32,
  ligatures : Bool,
  direction : @font.TextDirection,
  language : String,
  vertical : Bool,
) -> SvgTextRun raise {
  if sources.length() > 8 {
    raise Unsupported("SVG font has too many alternate sources: " + family)
  }
  let mut selected : (String, @font.TTFont)? = None
  for uri in sources {
    if !uri.has_prefix("data:") && uri.find("#") is Some(at) {
      let fragment = uri[at + 1:].to_owned()
      if svg_unescape(fragment, path=false) is Some(id) &&
        load(uri[:at].to_owned()) is Some(bytes) {
        let (_, root) = svg_parse_source(bytes)
        if svg_inline_font_by_id(root, id) is Some(font) {
          guard direction != Rtl && !vertical else {
            raise Unsupported("This SVG layout requires an OpenType font")
          }
          return svg_shape_inline_font(font, text, size, ligatures)
        }
      }
      continue
    }
    if fonts.get(uri) is Some(font) {
      selected = Some((uri, font))
      break
    }
    guard fonts.length() < 8 else {
      raise Unsupported("SVG exceeds the font resource count")
    }
    let bytes = match uri {
      "fallback:sans-serif" =>
        Some(@base64.decode(svg_fallback_sans[:], ignore_whitespace=true))
      "fallback:serif" =>
        Some(@base64.decode(svg_fallback_serif[:], ignore_whitespace=true))
      _ => svg_load_font(uri, load)
    }
    if bytes is Some(bytes) &&
      svg_font_directory_is_bounded(bytes[:]) &&
      @font.parse_font(bytes) is Some(font) {
      fonts[uri] = font
      selected = Some((uri, font))
      break
    }
  }
  guard selected is Some((uri, font)) else {
    raise Unsupported("Missing or invalid SVG font: " + sources.join(", "))
  }
  guard font.units_per_em > 0 else {
    raise Unsupported("Invalid SVG font size or units per em")
  }
  let axes : Map[String, Double] = Map([])
  if font.var_axes.any(axis => axis.tag == "wght") {
    axes["wght"] = desired_weight.to_double()
  }
  if vertical {
    let scale = size / font.units_per_em.to_double()
    let glyphs : Array[SvgRunGlyph] = []
    let mut end = 0
    let mut advance = 0.0
    for glyph in font.layout_text_vertical(text, size) {
      if glyph.glyph_id == 0 {
        raise Unsupported("SVG font is missing characters: " + uri)
      }
      let start = end
      end += if glyph.codepoint > 0xffff { 2 } else { 1 }
      let metrics = font.glyph_metrics_at(glyph.glyph_id, axes)
      glyphs.push({
        codepoint: glyph.codepoint,
        text_start: start,
        text_end: end,
        x: -metrics.advance_width.to_double() * scale / 2.0,
        y: glyph.y_offset + glyph.x_offset,
        advance_width: glyph.x_advance,
        outline: () => {
          @font.path_commands_to_svg_d(
            font.glyph_outline_at(glyph.glyph_id, axes),
          )
        },
      })
      advance += glyph.x_advance
    }
    return { glyphs, advance, scale, left_to_right: true, }
  }
  let shaped = font.shape_text(
    text,
    size,
    axis_values=axes,
    ligatures~,
    direction~,
    language~,
  ) catch {
    _ => raise Unsupported("Unable to shape text with SVG font: " + family)
  }
  if !shaped.missing_codepoints.is_empty() {
    raise Unsupported("SVG font is missing characters: " + uri)
  }
  {
    glyphs: shaped.bounds.glyphs.map(glyph => {
      codepoint: glyph.codepoint,
      text_start: glyph.text_start,
      text_end: glyph.text_end,
      x: glyph.x,
      y: glyph.y,
      advance_width: glyph.advance_width,
      outline: () => {
        @font.path_commands_to_svg_d(
          font.glyph_outline_at(glyph.glyph_id, shaped.variations),
        )
      },
    }),
    advance: shaped.bounds.advance_width,
    scale: size / font.units_per_em.to_double(),
    left_to_right: shaped.direction == "ltr",
  }
}

///|
fn svg_glyph_run(
  text : String,
  x : Double,
  y : Double,
  style : Map[String, String],
  faces : Map[String, Array[SvgFontFace]],
  fonts : Map[String, @font.TTFont],
  outline_size : Ref[Int32],
  load : (String) -> Bytes?,
  path~ : SvgTextPath? = None,
  positioning~ : Array[Array[Double]]? = None,
  length_adjust~ : (Double, Bool)? = None,
) -> (Array[@dom.Node], Double, Double) raise {
  if text.length() > 4096 {
    raise Unsupported("SVG text exceeds the shaping budget")
  }
  if text.is_empty() {
    return ([], x, y)
  }
  let size = svg_dimension(style.get("font-size").unwrap_or("16"))
  if size == 0.0 {
    return ([], x, y)
  }
  guard size <= 2048.0 else {
    raise Unsupported("SVG font size exceeds the rendering budget")
  }
  let family = style.get("font-family").unwrap_or("sans-serif")
  let desired_weight = svg_font_weight(
    style.get("font-weight").unwrap_or("normal"),
  )
  let desired_style = style.get("font-style").unwrap_or("normal")
  let mode = style.get("writing-mode").unwrap_or("horizontal-tb")
  let vertical = ["tb", "tb-rl", "vertical-rl", "vertical-lr"].contains(mode)
  guard vertical ||
    ["horizontal-tb", "lr", "lr-tb", "rl", "rl-tb"].contains(mode) else {
    raise Unsupported("Unsupported SVG writing mode: " + mode)
  }
  let rtl = style.get("direction").unwrap_or("ltr") == "rtl" ||
    mode == "rl" ||
    mode == "rl-tb"
  if vertical {
    guard !rtl && path is None && positioning is None && length_adjust is None else {
      raise Unsupported(
        "This combination of SVG vertical text and positioning is unsupported",
      )
    }
    let orientation = style.get("glyph-orientation-vertical").unwrap_or("auto")
    let upright = ["0", "0deg"].contains(orientation)
    guard (upright || orientation == "auto") &&
      text.all(character => {
        let code = character.to_int()
        code == 32 ||
        (code >= 0x3400 && code <= 0x4dbf) ||
        (code >= 0x4e00 && code <= 0x9fff) ||
        (upright && code >= 33 && code <= 126)
      }) else {
      raise Unsupported("Unsupported glyph orientation in SVG vertical text")
    }
  }
  let mut sources : Array[String] = []
  let mut embedded : SvgInlineFont? = None
  for choice in family.split(",") {
    let name = choice.trim().to_owned()
    let generic = name.to_lower()
    if generic == "sans-serif" || generic == "serif" {
      sources.push("fallback:" + generic)
      break
    }
    let candidate = svg_css_unquote(name).to_lower()
    if faces.get(candidate) is Some(variants) {
      let mut best = 10000
      for face in variants {
        let rank = 3000 * svg_font_style_rank(face.font_style, desired_style) +
          svg_font_weight_rank(face.weight, desired_weight)
        if rank <= best {
          sources = face.sources
          embedded = face.embedded
          best = rank
        }
      }
      if !sources.is_empty() || embedded is Some(_) {
        break
      }
    }
  }
  if sources.is_empty() && embedded is None {
    raise Unsupported("SVG text needs an in-document @font-face for " + family)
  }
  let letter_spacing = svg_spacing(style.get("letter-spacing"), size)
  let word_spacing = svg_spacing(style.get("word-spacing"), size)
  let ligatures = positioning is None && letter_spacing == 0.0
  let shaped = match embedded {
    Some(font) => {
      guard !rtl && !vertical else {
        raise Unsupported("This SVG layout requires an OpenType font")
      }
      svg_shape_inline_font(font, text, size, ligatures)
    }
    None =>
      svg_shape_font_sources(
        family,
        sources,
        fonts,
        load,
        text,
        size,
        desired_weight,
        ligatures,
        if rtl {
          Rtl
        } else {
          Ltr
        },
        style.get("language").unwrap_or("und"),
        vertical,
      )
  }
  let glyphs = shaped.glyphs
  let spacing_offsets : Array[Double] = []
  let mut spacing = 0.0
  let mut clusters = 0
  let cluster_indices : Array[Int32] = []
  for index, glyph in glyphs {
    spacing_offsets.push(spacing)
    cluster_indices.push(clusters)
    let ends_cluster = match glyphs.get(index + 1) {
      Some(next) => next.text_start != glyph.text_start
      None => true
    }
    if ends_cluster {
      clusters += 1
      spacing += letter_spacing
      if glyph.codepoint == 32 || glyph.codepoint == 160 {
        spacing += word_spacing
      }
    }
  }
  let advance = shaped.advance + spacing
  let (adjusted, width_scale, letter_gap) = match length_adjust {
    Some((target, true)) if advance > 0.0 => (target, target / advance, 0.0)
    Some((target, false)) if clusters > 1 =>
      (target, 1.0, (target - advance) / (clusters - 1).to_double())
    _ => (advance, 1.0, 0.0)
  }
  let anchor = match style.get("text-anchor").unwrap_or("start") {
    "start" => if rtl { adjusted } else { 0.0 }
    "middle" => adjusted / 2.0
    "end" => if rtl { 0.0 } else { adjusted }
    _ => raise Unsupported("Invalid SVG text-anchor")
  }
  let scale = shaped.scale
  let children : Array[@dom.Node] = []
  let mut shift_x = 0.0
  let mut shift_y = 0.0
  let mut angle = 0.0
  let offsets : Array[Int32] = [0]
  if positioning is Some(_) {
    for character in text {
      offsets.push(
        offsets[offsets.length() - 1] +
        (if character.to_int() > 0xffff { 2 } else { 1 }),
      )
    }
    if !shaped.left_to_right || shaped.glyphs.length() + 1 != offsets.length() {
      raise Unsupported(
        "SVG position lists require one glyph per character in left-to-right order",
      )
    }
  }
  for index, glyph in shaped.glyphs {
    if positioning is Some(lists) {
      if glyph.text_start != offsets[index] ||
        glyph.text_end != offsets[index + 1] {
        raise Unsupported(
          "SVG position lists require one glyph per character in left-to-right order",
        )
      }
      if lists[0].get(index) is Some(position) {
        shift_x = position - x - glyph.x - spacing_offsets[index]
      }
      if lists[1].get(index) is Some(position) {
        shift_y = position - y
      }
      shift_x += lists[2].get(index).unwrap_or(0.0)
      shift_y += lists[3].get(index).unwrap_or(0.0)
      angle = lists[4].get(index).unwrap_or(angle)
    }
    let d = (glyph.outline)()
    outline_size.val += d.length()
    if outline_size.val > 4194304 {
      raise Unsupported(
        "Expanded SVG text outlines exceed the rendering budget",
      )
    }
    if !d.is_empty() {
      let (gx, gy) = if vertical {
        (x + glyph.x, y + glyph.y - anchor + spacing_offsets[index])
      } else {
        (
          x -
          anchor +
          (glyph.x + spacing_offsets[index]) * width_scale +
          cluster_indices[index].to_double() * letter_gap +
          shift_x,
          y + glyph.y + shift_y,
        )
      }
      let transform = match path {
        Some(path) =>
          match path.glyph_transform(gx, gy, glyph.advance_width, scale) {
            Some(transform) => transform
            None => continue
          }
        None if angle != 0.0 => {
          let radians = angle * 3.141592653589793 / 180.0
          let cosine = @math.cos(radians) * scale
          let sine = @math.sin(radians) * scale
          let values = [cosine, sine, sine, -cosine, gx, gy]
          "matrix(" + values.map(value => value.to_string()).join(" ") + ")"
        }
        None =>
          "translate(" +
          gx.to_string() +
          " " +
          gy.to_string() +
          ") scale(" +
          (scale * width_scale).to_string() +
          " " +
          (-scale).to_string() +
          ")"
      }
      children.push(
        ElementNode(
          @dom.Element::new("path", attrs=[
            ("d", d),
            ("transform", transform),
            (
              "style", "fill:inherit !important;stroke:inherit !important;filter:none !important;mask:none !important;clip-path:none !important;opacity:1 !important",
            ),
          ]),
        ),
      )
    }
  }
  if vertical {
    (children, x, y - anchor + adjusted)
  } else {
    (children, x - anchor + adjusted + shift_x, y + shift_y)
  }
}

///|
fn svg_glyph_group(
  element : @dom.Element,
  style : Map[String, String],
  cursor : Ref[(Double, Double)],
  faces : Map[String, Array[SvgFontFace]],
  fonts : Map[String, @font.TTFont],
  outline_size : Ref[Int32],
  load : (String) -> Bytes?,
  paths : Map[String, @dom.Element],
  selector : @css.Element,
  sheets : Array[@css.Stylesheet],
  viewport : (Double, Double),
  path~ : SvgTextPath? = None,
) -> @dom.Element raise {
  if !element.child_elements().is_empty() &&
    ["tb", "tb-rl", "vertical-rl", "vertical-lr"].contains(
      style.get("writing-mode").unwrap_or("horizontal-tb"),
    ) {
    raise Unsupported("Nested SVG vertical text layout is unsupported")
  }
  let font_size = svg_dimension(style.get("font-size").unwrap_or("16"))
  let (width, height) = viewport
  let xs = svg_text_numbers(element, "x", font_size, width)
  let ys = svg_text_numbers(element, "y", font_size, height)
  let dx = svg_text_numbers(element, "dx", font_size, width)
  let dy = svg_text_numbers(element, "dy", font_size, height)
  let rotations = svg_text_numbers(element, "rotate", font_size, width)
  let lists = [xs, ys, dx, dy, rotations]
  let explicit = !rotations.is_empty() ||
    lists.any(values => values.length() > 1)
  if explicit &&
    (
      !element.child_elements().is_empty() ||
      style.get("text-anchor").unwrap_or("start") != "start"
    ) {
    raise Unsupported(
      "SVG position lists for anchored or nested text are unsupported",
    )
  }
  if explicit && path is Some(_) {
    raise Unsupported("SVG position lists on a path are unsupported")
  }
  let length_adjust = match element.attr("textLength") {
    None => None
    Some(value) => {
      if explicit || path is Some(_) || !element.child_elements().is_empty() {
        raise Unsupported(
          "SVG explicit text length with positions, spans, or paths is unsupported",
        )
      }
      let length = if value.has_suffix("%") {
        svg_viewport_axis(Some(value), width)
      } else {
        svg_relative_length(value, font_size)
      }
      guard length > 0.0 else {
        raise Unsupported("SVG textLength must be positive")
      }
      let stretch = match element.attr("lengthAdjust").unwrap_or("spacing") {
        "spacing" => false
        "spacingAndGlyphs" => true
        _ => raise Unsupported("Unsupported SVG lengthAdjust")
      }
      Some((length, stretch))
    }
  }
  let (previous_x, previous_y) = cursor.val
  let x = if explicit {
    previous_x
  } else {
    xs.get(0).unwrap_or(previous_x) + dx.get(0).unwrap_or(0.0)
  }
  let y = if explicit {
    previous_y
  } else {
    ys.get(0).unwrap_or(previous_y) + dy.get(0).unwrap_or(0.0)
  }
  cursor.val = (x, y)
  let mut children : Array[@dom.Node] = []
  let anchor = style.get("text-anchor").unwrap_or("start")
  let rtl = style.get("direction") == Some("rtl") ||
    ["rl", "rl-tb"].contains(style.get("writing-mode").unwrap_or(""))
  if !element.child_elements().is_empty() &&
    (rtl || @bidi.requires_bidi(element.text())) {
    if path is None && svg_unpositioned_spans(element) {
      let children = svg_bidi_glyphs(
        element, style, selector, sheets, x, y, faces, fonts, outline_size, load,
      )
      return svg_wrap_glyph_group(element, selector, sheets, children)
    }
    if rtl {
      raise Unsupported(
        "SVG bidirectional text spans define multiple positioning contexts",
      )
    }
  }
  if element.child_elements().is_empty() {
    let (paths, next_x, next_y) = svg_glyph_run(
      element.text(),
      x,
      y,
      style,
      faces,
      fonts,
      outline_size,
      load,
      path~,
      positioning=if explicit { Some(lists) } else { None },
      length_adjust~,
    )
    for path in paths {
      children.push(path)
    }
    cursor.val = (next_x, next_y)
  } else {
    let anchored = anchor != "start"
    if anchored && (path is Some(_) || !svg_unpositioned_spans(element)) {
      raise Unsupported(
        "Anchored SVG text spans define multiple positioning contexts",
      )
    }
    let layout = if anchored {
      let unanchored = style.copy()
      unanchored["text-anchor"] = "start"
      unanchored
    } else {
      style
    }
    let parent : @dom.Node = ElementNode(element)
    for node in parent.children() {
      match node {
        ElementNode(span) if ["tspan", "tref", "a"].contains(
            @dom.local_of(span.name),
          ) => {
          let span_selector = svg_text_selector(span, Some(selector))
          let span_style = svg_text_properties(
            span,
            layout,
            svg_text_cascade(span, span_selector, sheets),
          )
          children.push(
            ElementNode(
              svg_glyph_group(
                span,
                span_style,
                cursor,
                faces,
                fonts,
                outline_size,
                load,
                paths,
                span_selector,
                sheets,
                viewport,
                path~,
              ),
            ),
          )
        }
        ElementNode(run) if @dom.local_of(run.name) == "textPath" &&
          path is None => {
          let geometry = svg_text_path(run, paths, load~)
          let run_selector = svg_text_selector(run, Some(selector))
          let run_style = svg_text_properties(
            run,
            layout,
            svg_text_cascade(run, run_selector, sheets),
          )
          children.push(
            ElementNode(
              svg_glyph_group(
                run,
                run_style,
                Ref((0.0, y)),
                faces,
                fonts,
                outline_size,
                load,
                paths,
                run_selector,
                sheets,
                viewport,
                path=Some(geometry),
              ),
            ),
          )
        }
        ElementNode(other) =>
          raise Unsupported("Unsupported child within SVG text: " + other.name)
        TextNode(text) | CDataNode(text) => {
          let (current_x, current_y) = cursor.val
          let (paths, next_x, next_y) = svg_glyph_run(
            text,
            current_x,
            current_y,
            layout,
            faces,
            fonts,
            outline_size,
            load,
            path~,
          )
          for path in paths {
            children.push(path)
          }
          cursor.val = (next_x, next_y)
        }
        _ => ()
      }
    }
    if anchored {
      let (end_x, end_y) = cursor.val
      let shift = match anchor {
        "middle" => (x - end_x) / 2.0
        "end" => x - end_x
        _ => raise Unsupported("Invalid SVG text-anchor")
      }
      let inner = @dom.Element::new(
        "g",
        attrs=[("transform", "translate(" + shift.to_string() + " 0)")],
        children~,
      )
      children = [ElementNode(inner)]
      cursor.val = (end_x + shift, end_y)
    }
  }
  svg_wrap_glyph_group(element, selector, sheets, children)
}

///|
fn svg_wrap_glyph_group(
  element : @dom.Element,
  selector : @css.Element,
  sheets : Array[@css.Stylesheet],
  children : Array[@dom.Node],
) -> @dom.Element {
  let attrs = element.attrs.filter(pair => {
    !["x", "y", "dx", "dy", "rotate", "textLength", "lengthAdjust"].contains(
      pair.0,
    ) &&
    (
      @dom.local_of(element.name) != "textPath" ||
      ![
        "href", "startOffset", "method", "spacing", "{http://www.w3.org/1999/xlink}href",
      ].contains(pair.0)
    )
  })
  let group = @dom.Element::new("g", attrs~, children~)
  let computed = svg_text_cascade(element, selector, sheets)
  let style = StringBuilder()
  style.write_string(element.attr("style").unwrap_or(""))
  for
    name in [
      "fill", "stroke", "color", "opacity", "fill-opacity", "stroke-opacity", "stroke-width",
      "visibility", "display", "clip-path", "filter", "mask",
    ] {
    if computed.get_value(name) is Some(value) {
      style.write_string(";" + name + ":" + value + " !important")
    }
  }
  let inline = style.to_string()
  if !inline.is_empty() {
    group.set_attr("style", inline)
  }
  group
}

///|
fn svg_preserve_space(element : @dom.Element, inherited : Bool) -> Bool {
  match element.attr("{http://www.w3.org/XML/1998/namespace}space") {
    Some("default") => false
    Some("preserve") => true
    _ => inherited
  }
}

///|
fn svg_normalize_text_space(text : @dom.Element, inherited : Bool) -> Unit {
  let plans : Array[(@dom.Element, Array[(@dom.Node, StringBuilder?)])] = []
  let mut pending : StringBuilder? = None
  let mut may_add_space = false
  fn visit(element : @dom.Element, inherited : Bool) -> Unit {
    let preserve = svg_preserve_space(element, inherited)
    let node : @dom.Node = ElementNode(element)
    let plan : Array[(@dom.Node, StringBuilder?)] = []
    for child in node.children() {
      match child {
        ElementNode(info) if ["title", "desc", "metadata"].contains(
            @dom.local_of(info.name),
          ) => ()
        ElementNode(span) => {
          visit(span, preserve)
          plan.push((child, None))
        }
        TextNode(raw) | CDataNode(raw) => {
          let normalized = StringBuilder()
          for character in raw {
            let is_linebreak = character == '\n' || character == '\r'
            let is_space = character == ' ' || character == '\t' || is_linebreak
            if !preserve && is_space {
              if !is_linebreak && may_add_space && pending is None {
                pending = Some(normalized)
              }
            } else {
              if pending is Some(previous) {
                previous.write_char(' ')
                pending = None
              }
              normalized.write_char(if is_space { ' ' } else { character })
              may_add_space = !is_space
            }
          }
          plan.push((child, Some(normalized)))
        }
        _ => plan.push((child, None))
      }
    }
    plans.push((element, plan))
  }
  visit(text, inherited)
  for (element, plan) in plans {
    element.set_children(
      plan.map(item => {
        match item {
          (_, Some(value)) => TextNode(value.to_string())
          (node, None) => node
        }
      }),
    )
  }
}

///|
fn outline_svg_text(
  root : @dom.Element,
  base : String,
  load : (String) -> Bytes?,
  size : (Int32, Int32)?,
) -> Bool raise {
  let mut contains_text = false
  let styles : Array[String] = []
  let paths : Map[String, @dom.Element] = Map([])
  let faces : Map[String, Array[SvgFontFace]] = Map([])
  fn collect(element : @dom.Element) -> Unit {
    match @dom.local_of(element.name) {
      "style" => styles.push(element.text())
      "text" => contains_text = true
      "font" =>
        for descriptor in element.child_elements() {
          if @dom.local_of(descriptor.name) == "font-face" &&
            descriptor.attr("font-family") is Some(family) {
            let name = svg_css_unquote(family).to_lower()
            let variants = faces.get(name).unwrap_or([])
            variants.push({
              sources: [],
              embedded: Some({ metrics: descriptor, source: element, }),
              weight: svg_font_weight(
                descriptor.attr("font-weight").unwrap_or("normal"),
              ),
              font_style: descriptor.attr("font-style").unwrap_or("normal"),
            })
            faces[name] = variants
          }
        }
      "path" => if element.attr("id") is Some(id) { paths[id] = element }
      _ => ()
    }
    for child in element.child_elements() {
      collect(child)
    }
  }
  collect(root)
  if !contains_text {
    return false
  }
  let viewport = match svg_viewbox_size(root) {
    Some(view) => view
    None => {
      let (w, h) = match size {
        Some(dimensions) => dimensions
        None => svg_dimensions(root, None)
      }
      (w.to_double(), h.to_double())
    }
  }
  let visited : Map[String, Bool] = Map([])
  let sheets : Array[@css.Stylesheet] = []
  for style in styles {
    svg_font_faces_from_css(style, base, faces, sheets, visited, load, 0)
  }
  let fonts : Map[String, @font.TTFont] = Map([])
  let outline_size = Ref(0)
  let mut changed = false
  fn visit(
    element : @dom.Element,
    inherited : Map[String, String],
    parent : @css.Element?,
    preserve : Bool,
    viewport : (Double, Double),
  ) -> Unit raise {
    let preserve = svg_preserve_space(element, preserve)
    let selector = svg_text_selector(element, parent)
    let style = svg_text_properties(
      element,
      inherited,
      svg_text_cascade(element, selector, sheets),
    )
    for child in element.child_elements() {
      if @dom.local_of(child.name) == "text" {
        svg_normalize_text_space(child, preserve)
        let child_selector = svg_text_selector(child, Some(selector))
        let props = svg_text_properties(
          child,
          style,
          svg_text_cascade(child, child_selector, sheets),
        )
        let group = svg_glyph_group(
          child,
          props,
          Ref((0.0, 0.0)),
          faces,
          fonts,
          outline_size,
          load,
          paths,
          child_selector,
          sheets,
          viewport,
        )
        ignore(child.replace_with(ElementNode(group)))
        changed = true
      } else {
        let viewport = if @dom.local_of(child.name) == "svg" {
          match svg_viewbox_size(child) {
            Some(view) => view
            None => {
              let (w, h) = viewport
              (
                svg_viewport_axis(child.attr("width"), w),
                svg_viewport_axis(child.attr("height"), h),
              )
            }
          }
        } else {
          viewport
        }
        visit(child, style, Some(selector), preserve, viewport)
      }
    }
  }
  visit(root, Map([]), None, false, viewport)
  changed
}
