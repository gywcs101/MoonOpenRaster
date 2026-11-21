///|
priv struct SvgBidiPiece {
  style : Map[String, String]
  glyphs : Array[@dom.Node]
  override_direction : Bool
}

///|
priv struct SvgBidiPosition {
  x : Double?
  y : Double?
  dx : Double
  dy : Double
  rotate : Double
}

///|
priv struct SvgBidiCharacter {
  value : Char
  piece : Int32
  position : SvgBidiPosition
}

///|
let svg_bidi_default_position : SvgBidiPosition = {
  x: None,
  y: None,
  dx: 0.0,
  dy: 0.0,
  rotate: 0.0,
}

///|
fn svg_embedding_character(value : Char) -> SvgBidiCharacter {
  { value, piece: -1, position: svg_bidi_default_position, }
}

///|
fn svg_bidi_mode(
  element : @dom.Element,
  computed : @css.CascadedValues,
) -> String {
  computed
  .get_value("unicode-bidi")
  .unwrap_or(element.attr("unicode-bidi").unwrap_or("normal"))
}

///|
fn svg_has_bidi_mode(
  element : @dom.Element,
  selector : @css.Element,
  sheets : Array[@css.Stylesheet],
) -> Bool {
  if svg_bidi_mode(element, svg_text_cascade(element, selector, sheets)) !=
    "normal" {
    return true
  }
  element
  .child_elements()
  .any(child => {
    let child_selector = svg_text_selector(child, Some(selector))
    svg_has_bidi_mode(child, child_selector, sheets)
  })
}

///|
fn svg_bidi_control(rtl : Bool, override_direction : Bool) -> Char {
  match (rtl, override_direction) {
    (true, true) => '\u{202e}'
    (false, true) => '\u{202d}'
    (true, false) => '\u{202b}'
    (false, false) => '\u{202a}'
  }
}

///|
fn svg_bidi_glyphs(
  element : @dom.Element,
  style : Map[String, String],
  selector : @css.Element,
  sheets : Array[@css.Stylesheet],
  x : Double,
  y : Double,
  faces : Map[String, Array[SvgFontFace]],
  fonts : Map[String, @font.TTFont],
  outline_size : Ref[Int32],
  load : (String) -> Bytes?,
  positions : Array[Array[Double]],
  viewport : (Double, Double),
) -> Array[@dom.Node] raise {
  let characters : Array[SvgBidiCharacter] = []
  let pieces : Array[SvgBidiPiece] = []
  fn collect(
    element : @dom.Element,
    computed : @css.CascadedValues,
    style : Map[String, String],
    selector : @css.Element,
    parent_override : Bool,
    positions : Array[Array[Double]],
  ) -> (() -> Array[@dom.Node]) raise {
    let bidi_mode = svg_bidi_mode(element, computed)
    let override_direction = match bidi_mode {
      "normal" => parent_override
      "embed" => false
      "bidi-override" => true
      _ => raise Unsupported("Unsupported SVG unicode-bidi value: " + bidi_mode)
    }
    guard !element.has_attr("textLength") else {
      raise Unsupported(
        "Explicit length in SVG bidirectional text spans is unsupported",
      )
    }
    let embedded = bidi_mode != "normal"
    if embedded {
      let direction = svg_bidi_control(
        style.get("direction") == Some("rtl"),
        override_direction,
      )
      characters.push(svg_embedding_character(direction))
    }
    let children : Array[() -> Array[@dom.Node]] = []
    let node : @dom.Node = ElementNode(element)
    let mut offset = 0
    for child in node.children() {
      match child {
        TextNode(value) | CDataNode(value) if !value.is_empty() => {
          let glyphs : Array[@dom.Node] = []
          for character in value {
            let angle = positions[4]
            characters.push({
              value: character,
              piece: pieces.length(),
              position: {
                x: positions[0].get(offset),
                y: positions[1].get(offset),
                dx: positions[2].get(offset).unwrap_or(0.0),
                dy: positions[3].get(offset).unwrap_or(0.0),
                rotate: if angle.is_empty() {
                  0.0
                } else {
                  angle[offset.min(angle.length() - 1)]
                },
              },
            })
            offset += 1
          }
          pieces.push({ style, glyphs, override_direction, })
          children.push(() => glyphs)
        }
        ElementNode(span) => {
          let selector = svg_text_selector(span, Some(selector))
          let computed = svg_text_cascade(span, selector, sheets)
          let style = svg_text_properties(span, style, computed)
          guard !["tb", "tb-rl", "vertical-rl", "vertical-lr"].contains(
            style.get("writing-mode").unwrap_or(""),
          ) else {
            raise Unsupported(
              "Vertical SVG spans within horizontal text are unsupported",
            )
          }
          let (inherited, count) = svg_position_slice(
            positions,
            offset,
            span.text(),
          )
          offset += count
          let size = svg_dimension(style.get("font-size").unwrap_or("16"))
          let (width, height) = viewport
          let own = [
            svg_text_numbers(span, "x", size, width),
            svg_text_numbers(span, "y", size, height),
            svg_text_numbers(span, "dx", size, width),
            svg_text_numbers(span, "dy", size, height),
            svg_text_numbers(span, "rotate", size, width),
          ]
          let positions = svg_merge_position_lists(own, inherited)
          let nested = collect(
            span, computed, style, selector, override_direction, positions,
          )
          children.push(() => {
            [
              ElementNode(
                svg_wrap_glyph_group(span, selector, sheets, nested()),
              ),
            ]
          })
        }
        _ => ()
      }
    }
    if embedded {
      characters.push(svg_embedding_character('\u{202c}'))
    }
    () => {
      let result : Array[@dom.Node] = []
      for children in children {
        for glyph in children() {
          result.push(glyph)
        }
      }
      result
    }
  }
  let collect_glyphs = collect(
    element,
    svg_text_cascade(element, selector, sheets),
    style,
    selector,
    false,
    positions,
  )
  guard characters.length() <= 4096 else {
    raise Unsupported("SVG text exceeds the shaping budget")
  }
  fn paint_chunk(
    chunk : Array[SvgBidiCharacter],
    style : Map[String, String],
    x : Double,
    y : Double,
  ) -> (Double, Double) raise {
    let rtl = style.get("direction") == Some("rtl") ||
      ["rl", "rl-tb"].contains(style.get("writing-mode").unwrap_or(""))
    let direction : @bidi.Direction = if rtl { RTL } else { LTR }
    let chunk_text = StringBuilder()
    for entry in chunk {
      chunk_text.write_char(entry.value)
    }
    let paragraph = @bidi.process(chunk_text.to_string(), direction~)
    let run_for_character = Array::make(chunk.length(), 0)
    let runs : Array[(Int32, Bool, String, Array[SvgBidiPosition])] = []
    let mut previous_piece = -1
    let mut previous_level = -1
    let mut buffer = StringBuilder()
    let mut run_offsets : Array[SvgBidiPosition] = []
    for i, character in paragraph.chars {
      if paragraph.original_classes[i].is_x9_removed() {
        continue
      }
      let (piece, level) = (chunk[i].piece, paragraph.levels[i])
      if piece != previous_piece || level != previous_level {
        if previous_piece >= 0 {
          runs.push(
            (
              previous_piece,
              previous_level % 2 == 1,
              buffer.to_string(),
              run_offsets,
            ),
          )
        }
        buffer = StringBuilder()
        run_offsets = []
        previous_piece = piece
        previous_level = level
      }
      buffer.write_char(character)
      run_offsets.push(chunk[i].position)
      run_for_character[i] = runs.length()
    }
    if previous_piece >= 0 {
      runs.push(
        (
          previous_piece,
          previous_level % 2 == 1,
          buffer.to_string(),
          run_offsets,
        ),
      )
    }
    let mut advance = 0.0
    let mut baseline = y
    let mut adjustment_x = 0.0
    let painted : Array[(Double, Array[@dom.Node])?] = Array::make(
      runs.length(),
      None,
    )
    for i in @bidi.reorder(paragraph) {
      let run = run_for_character[i]
      if painted[run] is Some(_) {
        continue
      }
      let (piece, rtl, raw_text, offsets) = runs[run]
      let overridden = pieces[piece].override_direction
      let text = if overridden {
        svg_bidi_control(rtl, true).to_string() + raw_text + "\u{202c}"
      } else {
        raw_text
      }
      let style = pieces[piece].style.copy()
      style["direction"] = if rtl { "rtl" } else { "ltr" }
      style["writing-mode"] = "horizontal-tb"
      style["text-anchor"] = if rtl { "end" } else { "start" }
      let positions = if offsets.any(offset => {
          offset.dx != 0.0 || offset.dy != 0.0 || offset.rotate != 0.0
        }) {
        let values = [
          [],
          [],
          offsets.map(offset => offset.dx),
          offsets.map(offset => offset.dy),
          offsets.map(offset => offset.rotate),
        ]
        if overridden {
          for axis in 2..<values.length() {
            values[axis].insert(0, 0.0)
            values[axis].push(0.0)
          }
        }
        Some(values)
      } else {
        None
      }
      let (glyphs, width, next_y) = svg_glyph_run(
        text,
        0.0,
        baseline,
        style,
        faces,
        fonts,
        outline_size,
        load,
        positioning=positions,
        visual_advance=true,
      )
      painted[run] = Some((advance, glyphs))
      advance += width
      baseline = next_y
      adjustment_x += offsets.fold(init=0.0, (total, offset) => {
        total + offset.dx
      })
    }
    let natural_advance = advance - adjustment_x
    let anchor = match style.get("text-anchor").unwrap_or("start") {
      "start" => if rtl { natural_advance } else { 0.0 }
      "middle" => natural_advance / 2.0
      "end" => if rtl { 0.0 } else { natural_advance }
      _ => raise Unsupported("Invalid SVG text-anchor")
    }
    for run, result in painted {
      guard result is Some((offset, glyphs)) else { continue }
      let piece = runs[run].0
      let transform = "translate(" + (x - anchor + offset).to_string() + " 0)"
      pieces[piece].glyphs.push(
        ElementNode(
          @dom.Element::new(
            "g",
            attrs=[("transform", transform)],
            children=glyphs,
          ),
        ),
      )
    }
    let flow_end = if rtl { adjustment_x } else { advance }
    (x - anchor + flow_end, baseline)
  }

  // SVG applies Unicode bidi separately for each absolute text position.
  // Reopen any embeddings that span a chunk boundary without attaching
  // positioning data to the synthetic directional controls.
  let embeddings : Array[Char] = []
  let mut chunk : Array[SvgBidiCharacter] = []
  let mut chunk_style = style
  let mut chunk_x = x
  let mut chunk_y = y
  let mut has_text = false
  for character in characters {
    let owner = character.piece
    let position = character.position
    if owner >= 0 {
      if position.x is Some(_) || position.y is Some(_) {
        if has_text {
          let (end_x, end_y) = paint_chunk(chunk, chunk_style, chunk_x, chunk_y)
          chunk_x = end_x
          chunk_y = end_y
          chunk = embeddings.map(svg_embedding_character)
          chunk_style = pieces[owner].style
        }
        chunk_x = position.x.unwrap_or(chunk_x)
        chunk_y = position.y.unwrap_or(chunk_y)
      }
      has_text = true
    }
    match character.value {
      '\u{202a}' | '\u{202b}' | '\u{202d}' | '\u{202e}' => {
        guard embeddings.length() < 125 else {
          raise Unsupported("SVG text exceeds the bidi embedding budget")
        }
        embeddings.push(character.value)
      }
      '\u{202c}' => ignore(embeddings.pop())
      _ => ()
    }
    chunk.push(character)
  }
  if has_text {
    ignore(paint_chunk(chunk, chunk_style, chunk_x, chunk_y))
  }
  collect_glyphs()
}
