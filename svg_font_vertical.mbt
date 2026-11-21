///|
fn svg_vertical_han(code : Int32) -> Bool {
  (code >= 0x3400 && code <= 0x4dbf) || (code >= 0x4e00 && code <= 0x9fff)
}

///|
fn svg_vertical_substitutions(
  font : @font.TTFont,
  text : String,
  axes : Map[String, Double],
  language : String,
) -> Map[Int32, Int32] raise OraError {
  guard @swash.FontRef::from_offset(font.data, font.sfnt_offset) is Some(face) else {
    raise Unsupported("Invalid OpenType font in SVG vertical layout")
  }
  let replacements : Map[Int32, Int32] = Map([])
  let vertical_tag = 0x76657274U // vert
  if !face.features().iter().any(feature => feature.tag() == vertical_tag) {
    return replacements
  }
  let context = @swash_shape.ShapeContext::ShapeContext()
  let features : Array[@swash.Setting[UInt16]] = [
    @swash.Setting::Setting(vertical_tag, (1).to_uint16()),
  ]
  let variations : Array[@swash.Setting[Double]] = []
  if axes.get("wght") is Some(weight) {
    variations.push(@swash.Setting::Setting(0x77676874U, weight))
  }
  let shaper = context
    .builder(face)
    .script(@swash.Han)
    .language(@swash.Language::parse(language))
    .features(features.iter())
    .variations(variations.iter())
    .build()
  let mut offset = 0
  let tokens : Array[@swash.Token] = []
  for character in text {
    let length = if character.to_int() > 0xffff { 2 } else { 1 }
    tokens.push(
      @swash.Token::Token(
        character,
        offset.reinterpret_as_uint(),
        length.reinterpret_as_uint(),
        @swash.CharInfo::from_char(character),
        0U,
      ),
    )
    offset += length
  }
  let parser = @swash.Parser::Parser(@swash.Han, tokens.iter())
  let cluster = @swash.CharCluster::CharCluster()
  let charmap = @swash.Charmap::from_font(face)
  while parser.next(cluster) {
    ignore(cluster.map(character => charmap.map(character.to_uint())))
    shaper.add_cluster(cluster)
  }
  let mut complex = false
  shaper.shape_with(cluster => {
    let glyphs = cluster.glyphs()
    let source = cluster.source()
    if glyphs.length() == 1 && source.end() - source.start() == 1U {
      replacements[source.start().reinterpret_as_int()] = glyphs[0]
        .id()
        .to_int()
    } else {
      complex = true
    }
  })
  guard !complex else {
    raise Unsupported("Complex vertical OpenType substitutions are unsupported")
  }
  replacements
}

///|
fn svg_vertical_open_type(
  font : @font.TTFont,
  text : String,
  size : Double,
  axes : Map[String, Double],
  orientation : String,
  ligatures : Bool,
  language : String,
  uri : String,
) -> SvgTextRun raise {
  let scale = size / font.units_per_em.to_double()
  let mut previous : Bool? = None
  let mut buffered = StringBuilder()
  let runs : Array[(Bool, String)] = []
  for character in text {
    let upright = match orientation {
      "0" | "0deg" => true
      "auto" => svg_vertical_han(character.to_int())
      _ => false
    }
    if previous is Some(prior) && prior != upright {
      runs.push((prior, buffered.to_string()))
      buffered = StringBuilder()
    }
    previous = Some(upright)
    buffered.write_char(character)
  }
  if previous is Some(upright) {
    runs.push((upright, buffered.to_string()))
  }
  let glyphs : Array[SvgRunGlyph] = []
  let mut advance = 0.0
  let mut offset = 0
  for (upright, text) in runs {
    if upright {
      let mut end = offset
      let layout = font.layout_text_vertical(text, size)
      let substitutes = svg_vertical_substitutions(font, text, axes, language)
      for glyph in layout {
        if glyph.glyph_id == 0 {
          raise Unsupported("SVG font is missing characters: " + uri)
        }
        let start = end
        end += if glyph.codepoint > 0xffff { 2 } else { 1 }
        let id = substitutes.get(start - offset).unwrap_or(glyph.glyph_id)
        let metrics = font.glyph_metrics_at(id, axes)
        let step = if id != glyph.glyph_id && font.vertical is Some(vertical) {
          vertical.advance_heights
          .get(id)
          .unwrap_or(font.units_per_em)
          .to_double() *
          scale
        } else {
          glyph.x_advance
        }
        glyphs.push({
          codepoint: glyph.codepoint,
          text_start: start,
          text_end: end,
          x: -metrics.advance_width.to_double() * scale / 2.0,
          y: advance + font.vert_origin_y(id).to_double() * scale,
          advance_width: step,
          scale,
          sideways: false,
          outline: () => {
            @font.path_commands_to_svg_d(font.glyph_outline_at(id, axes))
          },
        })
        advance += step
      }
    } else {
      let run = font.shape_text(
        text,
        size,
        axis_values=axes,
        ligatures~,
        direction=Ltr,
        language~,
      ) catch {
        _ =>
          raise Unsupported(
            "Unable to shape sideways text with SVG font: " + uri,
          )
      }
      guard run.missing_codepoints.is_empty() else {
        raise Unsupported("SVG font is missing characters: " + uri)
      }
      let baseline = -(font.ascent + font.descent).to_double() * scale / 2.0
      for glyph in run.bounds.glyphs {
        let placed = svg_positioned_glyph(
          font,
          glyph,
          run.variations,
          size,
          0.0,
          offset,
        )
        glyphs.push({
          ..placed,
          x: baseline - placed.y,
          y: advance + placed.x,
          sideways: true,
        })
      }
      advance += run.bounds.advance_width
    }
    offset += text.length()
  }
  { glyphs, advance, left_to_right: true, }
}
