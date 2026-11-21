///|
fn svg_vertical_han(code : Int32) -> Bool {
  (code >= 0x3400 && code <= 0x4dbf) || (code >= 0x4e00 && code <= 0x9fff)
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
      for glyph in layout {
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
          y: advance + glyph.y_offset + glyph.x_offset,
          advance_width: glyph.x_advance,
          scale,
          sideways: false,
          outline: () => {
            @font.path_commands_to_svg_d(
              font.glyph_outline_at(glyph.glyph_id, axes),
            )
          },
        })
      }
      // The shaper reports y offsets relative to this upright run's origin.
      for glyph in layout {
        advance += glyph.x_advance
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
