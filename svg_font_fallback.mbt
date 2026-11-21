///|
fn svg_positioned_glyph(
  font : @font.TTFont,
  glyph : @font.PositionedGlyphBounds,
  variations : Map[String, Double],
  size : Double,
  offset : Double,
  start : Int32,
) -> SvgRunGlyph {
  {
    codepoint: glyph.codepoint,
    text_start: start + glyph.text_start,
    text_end: start + glyph.text_end,
    x: offset + glyph.x,
    y: glyph.y,
    advance_width: glyph.advance_width,
    scale: size / font.units_per_em.to_double(),
    outline: () => {
      @font.path_commands_to_svg_d(
        font.glyph_outline_at(glyph.glyph_id, variations),
      )
    },
  }
}

///|
fn svg_fallback_glyphs(
  primary : @font.ShapedText,
  font : @font.TTFont,
  uri : String,
  fallbacks : Array[Array[String]],
  fonts : Map[String, @font.TTFont],
  load : (String) -> Bytes?,
  text : String,
  size : Double,
  weight : Int32,
  ligatures : Bool,
  language : String,
) -> SvgTextRun raise {
  let unavailable = "SVG font is missing characters: " + uri
  guard !fallbacks.is_empty() && fallbacks.length() <= 8 else {
    raise Unsupported(unavailable)
  }
  let candidates : Array[@font.TTFont] = []
  for sources in fallbacks {
    guard sources.length() <= 8 else {
      raise Unsupported("SVG fallback has too many alternate sources")
    }
    for source in sources {
      if !source.has_prefix("data:") && source.contains("#") {
        continue
      }
      if svg_font_for_uri(source, fonts, load) is Some(face) {
        candidates.push(face)
        break
      }
    }
  }
  fn backup(
    text : String,
    direction : @font.TextDirection,
  ) -> (@font.TTFont, @font.ShapedText)? {
    for face in candidates {
      let shaped = face.shape_text(
        text,
        size,
        direction~,
        language~,
        ligatures~,
        font_weight=weight.to_double(),
      ) catch {
        _ => continue
      }
      if shaped.missing_codepoints.is_empty() {
        return Some((face, shaped))
      }
    }
    None
  }
  let glyphs = primary.bounds.glyphs
  if glyphs.all(glyph => glyph.glyph_id == 0) {
    let direction : @font.TextDirection = if primary.direction == "rtl" {
      Rtl
    } else {
      Ltr
    }
    guard backup(text, direction) is Some((face, shaped)) else {
      raise Unsupported(unavailable)
    }
    return {
      glyphs: shaped.bounds.glyphs.map(glyph => {
        svg_positioned_glyph(face, glyph, shaped.variations, size, 0.0, 0)
      }),
      advance: shaped.bounds.advance_width,
      left_to_right: shaped.direction == "ltr",
    }
  }
  let result : Array[SvgRunGlyph] = []
  let replaced : Map[Int32, Bool] = Map([])
  let mut shift = 0.0
  for i = 0; i < glyphs.length(); {
    let first = glyphs[i]
    let mut end = i + 1
    while end < glyphs.length() &&
          glyphs[end].text_start == first.text_start &&
          glyphs[end].text_end == first.text_end {
      end += 1
    }
    let cluster = text[first.text_start:first.text_end].to_owned()
    let missing : Array[Int32] = []
    for character in cluster {
      if primary.missing_codepoints.contains(character.to_int()) {
        missing.push(character.to_int())
      }
    }
    if missing.is_empty() {
      for index in i..<end {
        result.push(
          svg_positioned_glyph(
            font,
            glyphs[index],
            primary.variations,
            size,
            shift,
            0,
          ),
        )
      }
      continue end
    }
    let direction : @font.TextDirection = if primary.runs.any(run => {
        i >= run.glyph_start && i < run.glyph_end && run.level % 2 == 1
      }) {
      Rtl
    } else {
      Ltr
    }
    guard backup(cluster, direction) is Some((fallback, shape)) else {
      raise Unsupported(unavailable)
    }
    for glyph in shape.bounds.glyphs {
      result.push(
        svg_positioned_glyph(
          fallback,
          glyph,
          shape.variations,
          size,
          first.x + shift,
          first.text_start,
        ),
      )
    }
    let mut replaced_advance = 0.0
    for index in i..<end {
      replaced_advance += glyphs[index].advance_width
    }
    shift += shape.bounds.advance_width - replaced_advance
    for codepoint in missing {
      replaced[codepoint] = true
    }
    continue end
  }
  guard primary.missing_codepoints.all(codepoint => replaced.contains(codepoint)) else {
    raise Unsupported(unavailable)
  }
  {
    glyphs: result,
    advance: primary.bounds.advance_width + shift,
    left_to_right: primary.direction == "ltr",
  }
}
