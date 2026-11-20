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
  uri : String
  weight : Int32
  font_style : String
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
      properties.get("src") is Some(source) &&
      source.has_prefix("url(") &&
      source.find(")") is Some(close) {
      let href = svg_css_unquote(source[4:close].to_owned())
      let uri = if href.has_prefix("data:") {
        Some(href)
      } else {
        svg_archive_path(base, href).map(svg_archive_uri)
      }
      if uri is Some(uri) {
        let name = svg_css_unquote(family).to_lower()
        let variants = faces.get(name).unwrap_or([])
        variants.push({
          uri,
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
fn svg_text_properties(
  element : @dom.Element,
  inherited : Map[String, String],
  computed : @css.CascadedValues,
) -> Map[String, String] {
  let properties = inherited.copy()
  for
    name in [
      "font-family", "font-size", "font-weight", "font-style", "text-anchor", "letter-spacing",
      "word-spacing",
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
      properties[name] = if name == "font-weight" &&
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
fn svg_text_numbers(
  element : @dom.Element,
  name : String,
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
      if name == "rotate" {
        result.push(svg_number(item.to_owned()))
      } else {
        result.push(svg_dimension(item.to_owned()))
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
    @dom.local_of(child.name) == "tspan" &&
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
    Some(raw) => {
      let trimmed = raw[:].trim().to_owned()
      if trimmed.has_suffix("em") {
        svg_number(trimmed[:trimmed.length() - 2].to_owned()) * size
      } else {
        svg_dimension(trimmed)
      }
    }
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
  let family = style.get("font-family").unwrap_or("sans-serif")
  let desired_weight = svg_font_weight(
    style.get("font-weight").unwrap_or("normal"),
  )
  let desired_style = style.get("font-style").unwrap_or("normal")
  let mut uri = None
  for choice in family.split(",") {
    let candidate = svg_css_unquote(choice.to_owned()).to_lower()
    if choice[:].trim().to_owned().to_lower() == "sans-serif" {
      uri = Some("fallback:sans-serif")
      break
    }
    if choice[:].trim().to_owned().to_lower() == "serif" {
      uri = Some("fallback:serif")
      break
    }
    if faces.get(candidate) is Some(variants) {
      let mut best = 10000
      for face in variants {
        let rank = 3000 * svg_font_style_rank(face.font_style, desired_style) +
          svg_font_weight_rank(face.weight, desired_weight)
        if rank <= best {
          uri = Some(face.uri)
          best = rank
        }
      }
      if uri is Some(_) {
        break
      }
    }
  }
  guard uri is Some(uri) else {
    raise Unsupported("SVG text needs an in-document @font-face for " + family)
  }
  let font = match fonts.get(uri) {
    Some(font) => font
    None => {
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
      guard bytes is Some(bytes) &&
        bytes.length() <= 8388608 &&
        @font.parse_font(bytes) is Some(font) else {
        raise Unsupported("Missing or invalid SVG font: " + uri)
      }
      fonts[uri] = font
      font
    }
  }
  let size = svg_dimension(style.get("font-size").unwrap_or("16"))
  guard size > 0.0 && size <= 2048.0 && font.units_per_em > 0 else {
    raise Unsupported("Invalid SVG font size or units per em")
  }
  let letter_spacing = svg_spacing(style.get("letter-spacing"), size)
  let word_spacing = svg_spacing(style.get("word-spacing"), size)
  let axes : Map[String, Double] = Map([])
  if font.var_axes.any(axis => axis.tag == "wght") {
    axes["wght"] = desired_weight.to_double()
  }
  let shaped = font.shape_text(
    text,
    size,
    axis_values=axes,
    ligatures=positioning is None && letter_spacing == 0.0,
  ) catch {
    _ => raise Unsupported("Unable to shape text with SVG font: " + family)
  }
  if !shaped.missing_codepoints.is_empty() {
    raise Unsupported("SVG font is missing characters: " + uri)
  }
  let glyphs = shaped.bounds.glyphs
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
  let advance = shaped.bounds.advance_width + spacing
  let (adjusted, width_scale, letter_gap) = match length_adjust {
    Some((target, true)) if advance > 0.0 => (target, target / advance, 0.0)
    Some((target, false)) if clusters > 1 =>
      (target, 1.0, (target - advance) / (clusters - 1).to_double())
    _ => (advance, 1.0, 0.0)
  }
  let anchor = match style.get("text-anchor").unwrap_or("start") {
    "start" => 0.0
    "middle" => adjusted / 2.0
    "end" => adjusted
    _ => raise Unsupported("Invalid SVG text-anchor")
  }
  let scale = size / font.units_per_em.to_double()
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
    if shaped.direction != "ltr" ||
      shaped.bounds.glyphs.length() + 1 != offsets.length() {
      raise Unsupported(
        "SVG position lists require one glyph per character in left-to-right order",
      )
    }
  }
  for index, glyph in shaped.bounds.glyphs {
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
    let d = @font.path_commands_to_svg_d(
      font.glyph_outline_at(glyph.glyph_id, shaped.variations),
    )
    outline_size.val += d.length()
    if outline_size.val > 4194304 {
      raise Unsupported(
        "Expanded SVG text outlines exceed the rendering budget",
      )
    }
    if !d.is_empty() {
      let gx = x -
        anchor +
        (glyph.x + spacing_offsets[index]) * width_scale +
        cluster_indices[index].to_double() * letter_gap +
        shift_x
      let gy = y + glyph.y + shift_y
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
  (children, x - anchor + adjusted + shift_x, y + shift_y)
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
  path~ : SvgTextPath? = None,
) -> @dom.Element raise {
  let xs = svg_text_numbers(element, "x")
  let ys = svg_text_numbers(element, "y")
  let dx = svg_text_numbers(element, "dx")
  let dy = svg_text_numbers(element, "dy")
  let rotations = svg_text_numbers(element, "rotate")
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
      let length = svg_dimension(value)
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
        ElementNode(span) if @dom.local_of(span.name) == "tspan" => {
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
                path~,
              ),
            ),
          )
        }
        ElementNode(run) if @dom.local_of(run.name) == "textPath" &&
          path is None => {
          let geometry = svg_text_path(run, paths)
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
fn outline_svg_text(
  root : @dom.Element,
  base : String,
  load : (String) -> Bytes?,
) -> Bool raise {
  let mut contains_text = false
  let styles : Array[String] = []
  let paths : Map[String, @dom.Element] = Map([])
  fn collect(element : @dom.Element) -> Unit {
    match @dom.local_of(element.name) {
      "style" => styles.push(element.text())
      "text" => contains_text = true
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
  let faces : Map[String, Array[SvgFontFace]] = Map([])
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
  ) -> Unit raise {
    let selector = svg_text_selector(element, parent)
    let style = svg_text_properties(
      element,
      inherited,
      svg_text_cascade(element, selector, sheets),
    )
    for child in element.child_elements() {
      if @dom.local_of(child.name) == "text" {
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
        )
        ignore(child.replace_with(ElementNode(group)))
        changed = true
      } else {
        visit(child, style, Some(selector))
      }
    }
  }
  visit(root, Map([]), None)
  changed
}
