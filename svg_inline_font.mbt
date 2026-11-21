///|
priv struct SvgRunGlyph {
  codepoint : Int32
  text_start : Int32
  text_end : Int32
  x : Double
  y : Double
  advance_width : Double
  scale : Double
  sideways : Bool
  outline : () -> String
}

///|
priv struct SvgTextRun {
  glyphs : Array[SvgRunGlyph]
  advance : Double
  left_to_right : Bool
}

///|
priv struct SvgInlineFont {
  metrics : @dom.Element
  source : @dom.Element
}

///|
fn svg_inline_font_by_id(root : @dom.Element, id : String) -> SvgInlineFont? {
  if @dom.local_of(root.name) == "font" && root.attr("id") == Some(id) {
    for descriptor in root.child_elements() {
      if @dom.local_of(descriptor.name) == "font-face" {
        return Some({ metrics: descriptor, source: root, })
      }
    }
  }
  for child in root.child_elements() {
    if svg_inline_font_by_id(child, id) is Some(font) {
      return Some(font)
    }
  }
  None
}

///|
priv struct SvgOutlineGlyph {
  unicode : String
  name : String
  width : Double
  outline : String
}

///|
fn svg_outline_glyph(
  element : @dom.Element,
  default_width : Double,
) -> SvgOutlineGlyph raise {
  let outline = StringBuilder()
  outline.write_string(element.attr("d").unwrap_or(""))
  for child in element.child_elements() {
    guard @dom.local_of(child.name) == "path" &&
      child.attrs.length() == 1 &&
      child.attr("d") is Some(path) else {
      raise Unsupported("SVG font glyph uses a graphic other than a plain path")
    }
    outline.write_char(' ')
    outline.write_string(path)
  }
  {
    unicode: element.attr("unicode").unwrap_or(""),
    name: element.attr("glyph-name").unwrap_or(""),
    width: match element.attr("horiz-adv-x") {
      Some(value) => svg_number(value)
      None => default_width
    },
    outline: outline.to_string(),
  }
}

///|
fn svg_kern_selector(
  rule : @dom.Element,
  unicode : String,
  names : String,
  glyph : SvgOutlineGlyph,
) -> Bool {
  rule
  .attr(unicode)
  .unwrap_or("")
  .split(",")
  .any(value => {
    let value = value.trim().to_owned()
    !value.is_empty() && value == glyph.unicode
  }) ||
  rule
  .attr(names)
  .unwrap_or("")
  .split(",")
  .any(value => {
    let value = value.trim().to_owned()
    !value.is_empty() && value == glyph.name
  })
}

///|
fn svg_shape_inline_font(
  font : SvgInlineFont,
  text : String,
  size : Double,
  ligatures : Bool,
) -> SvgTextRun raise {
  let units = svg_number(font.metrics.attr("units-per-em").unwrap_or("1000"))
  guard units > 0.0 else { raise Unsupported("Invalid SVG font units per em") }
  let default_width = svg_number(font.source.attr("horiz-adv-x").unwrap_or("0"))
  let scale = size / units
  let origin_x = svg_number(font.source.attr("horiz-origin-x").unwrap_or("0")) *
    scale
  let origin_y = svg_number(font.source.attr("horiz-origin-y").unwrap_or("0")) *
    scale
  let available : Array[SvgOutlineGlyph] = []
  let mut missing = None
  let kern : Array[(@dom.Element, Double)] = []
  for element in font.source.child_elements() {
    match @dom.local_of(element.name) {
      "glyph" => {
        let glyph = svg_outline_glyph(element, default_width)
        if !glyph.unicode.is_empty() {
          available.push(glyph)
        }
      }
      "missing-glyph" =>
        missing = Some(svg_outline_glyph(element, default_width))
      "hkern" =>
        kern.push(
          (element, svg_number(element.attr("k").unwrap_or("0")) * scale),
        )
      _ => ()
    }
  }
  let mut at = 0
  let mut x = 0.0
  let mut previous : SvgOutlineGlyph? = None
  let glyphs : Array[SvgRunGlyph] = []
  while at < text.length() {
    let mut codepoint = 0
    for character in text[at:] {
      codepoint = character.to_int()
      break
    }
    let char_length = if codepoint > 0xffff { 2 } else { 1 }
    let rest = text[at:]
    let mut matched : SvgOutlineGlyph? = None
    let mut length = 0
    for glyph in available {
      if glyph.unicode.length() > length &&
        (ligatures || glyph.unicode.length() == char_length) &&
        rest.has_prefix(glyph.unicode) {
        matched = Some(glyph)
        length = glyph.unicode.length()
      }
    }
    let glyph = match matched {
      Some(glyph) => glyph
      None => {
        guard missing is Some(glyph) else {
          raise Unsupported("Embedded SVG font is missing a glyph")
        }
        length = char_length
        glyph
      }
    }
    if previous is Some(prior) {
      for (rule, adjustment) in kern {
        if svg_kern_selector(rule, "u1", "g1", prior) &&
          svg_kern_selector(rule, "u2", "g2", glyph) {
          x -= adjustment
          break
        }
      }
    }
    let advance = glyph.width * scale
    glyphs.push({
      codepoint,
      text_start: at,
      text_end: at + length,
      x: x - origin_x,
      y: origin_y,
      advance_width: advance,
      scale,
      sideways: false,
      outline: () => glyph.outline,
    })
    previous = Some(glyph)
    x += advance
    at += length
  }
  { glyphs, advance: x, left_to_right: true, }
}
