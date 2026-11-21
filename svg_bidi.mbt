///|
priv struct SvgBidiPiece {
  style : Map[String, String]
  glyphs : Array[@dom.Node]
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
) -> Array[@dom.Node] raise {
  let text = StringBuilder()
  let owners : Array[Int32] = []
  let pieces : Array[SvgBidiPiece] = []
  fn collect(
    element : @dom.Element,
    computed : @css.CascadedValues,
    style : Map[String, String],
    selector : @css.Element,
  ) -> (() -> Array[@dom.Node]) raise {
    let bidi_mode = computed
      .get_value("unicode-bidi")
      .unwrap_or(element.attr("unicode-bidi").unwrap_or("normal"))
    let embedded = bidi_mode == "embed"
    guard (bidi_mode == "normal" || embedded) && !element.has_attr("textLength") else {
      raise Unsupported(
        "Unsupported bidi override or explicit length in SVG text spans",
      )
    }
    if embedded {
      owners.push(-1)
      text.write_char(
        if style.get("direction") == Some("rtl") {
          '\u{202b}'
        } else {
          '\u{202a}'
        },
      )
    }
    let children : Array[() -> Array[@dom.Node]] = []
    let node : @dom.Node = ElementNode(element)
    for child in node.children() {
      match child {
        TextNode(value) | CDataNode(value) if !value.is_empty() => {
          let glyphs : Array[@dom.Node] = []
          for character in value {
            owners.push(pieces.length())
            text.write_char(character)
          }
          pieces.push({ style, glyphs, })
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
          let nested = collect(span, computed, style, selector)
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
      owners.push(-1)
      text.write_char('\u{202c}')
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
  )
  guard owners.length() <= 4096 else {
    raise Unsupported("SVG text exceeds the shaping budget")
  }
  let rtl = style.get("direction") == Some("rtl") ||
    ["rl", "rl-tb"].contains(style.get("writing-mode").unwrap_or(""))
  let direction : @bidi.Direction = if rtl { RTL } else { LTR }
  let paragraph = @bidi.process(text.to_string(), direction~)
  let run_for_character = Array::make(owners.length(), 0)
  let runs : Array[(Int32, Bool, String)] = []
  let mut previous_piece = -1
  let mut previous_level = -1
  let mut buffer = StringBuilder()
  for i, character in paragraph.chars {
    if paragraph.original_classes[i].is_x9_removed() {
      continue
    }
    let (piece, level) = (owners[i], paragraph.levels[i])
    if piece != previous_piece || level != previous_level {
      if previous_piece >= 0 {
        runs.push((previous_piece, previous_level % 2 == 1, buffer.to_string()))
      }
      buffer = StringBuilder()
      previous_piece = piece
      previous_level = level
    }
    buffer.write_char(character)
    run_for_character[i] = runs.length()
  }
  if previous_piece >= 0 {
    runs.push((previous_piece, previous_level % 2 == 1, buffer.to_string()))
  }
  let mut advance = 0.0
  let painted : Array[(Double, Array[@dom.Node])?] = Array::make(
    runs.length(),
    None,
  )
  for i in @bidi.reorder(paragraph) {
    let run = run_for_character[i]
    if painted[run] is Some(_) {
      continue
    }
    let (piece, rtl, text) = runs[run]
    let style = pieces[piece].style.copy()
    style["direction"] = if rtl { "rtl" } else { "ltr" }
    style["writing-mode"] = "horizontal-tb"
    style["text-anchor"] = if rtl { "end" } else { "start" }
    let (glyphs, width, _) = svg_glyph_run(
      text, 0.0, y, style, faces, fonts, outline_size, load,
    )
    painted[run] = Some((advance, glyphs))
    advance += width
  }
  let anchor = match style.get("text-anchor").unwrap_or("start") {
    "start" => if rtl { advance } else { 0.0 }
    "middle" => advance / 2.0
    "end" => if rtl { 0.0 } else { advance }
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
  collect_glyphs()
}
