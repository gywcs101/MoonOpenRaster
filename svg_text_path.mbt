///|
priv struct SvgTextSegment {
  x : Double
  y : Double
  tx : Double
  ty : Double
  start : Double
  end : Double
}

///|
priv struct SvgTextPath {
  segments : Array[SvgTextSegment]
  length : Double
  offset : Double
  distance_scale : Double
}

///|
fn svg_text_path(
  element : @dom.Element,
  paths : Map[String, @dom.Element],
  load~ : (String) -> Bytes? = _ => None,
) -> SvgTextPath raise {
  let href = element
    .attr("href")
    .unwrap_or(element.attr("{http://www.w3.org/1999/xlink}href").unwrap_or(""))
  guard href.find("#") is Some(fragment) &&
    svg_unescape(href[fragment + 1:].to_owned(), path=false) is Some(id) &&
    !id.is_empty() else {
    raise Unsupported("SVG textPath requires a path id: " + href)
  }
  let path = if fragment == 0 {
    paths.get(id)
  } else {
    guard load(href[:fragment].to_owned()) is Some(resource) else {
      raise Unsupported("Missing SVG textPath resource: " + href)
    }
    let (_, root) = svg_parse_source(resource)
    fn lookup(node : @dom.Element) -> @dom.Element? {
      if @dom.local_of(node.name) == "path" && node.attr("id") == Some(id) {
        return Some(node)
      }
      for child in node.child_elements() {
        if lookup(child) is Some(target) {
          return Some(target)
        }
      }
      None
    }
    lookup(root)
  }
  guard path is Some(path) else {
    raise Unsupported("Unresolved SVG textPath: " + href)
  }
  if element.attr("method").unwrap_or("align") != "align" ||
    element.attr("spacing").unwrap_or("exact") != "exact" {
    raise Unsupported("Unsupported SVG text-path geometry or spacing")
  }
  let segments : Array[SvgTextSegment] = []
  let transform = @vector.parse_transform(path.attr("transform").unwrap_or(""))
  let mut length = 0.0
  let mut x = 0.0
  let mut y = 0.0
  let mut origin = (0.0, 0.0)
  let mut control : (Double, Double, Bool)? = None
  fn line(next_x : Double, next_y : Double) -> Unit raise OraError {
    let (px, py) = transform.apply(x, y)
    let (qx, qy) = transform.apply(next_x, next_y)
    let dx = qx - px
    let dy = qy - py
    let distance = (dx * dx + dy * dy).sqrt()
    if !distance.is_finite() || segments.length() >= 32768 {
      raise Unsupported("Invalid or oversized SVG text path")
    }
    if distance > 0.0 {
      let end = length + distance
      segments.push({
        x: px,
        y: py,
        tx: dx / distance,
        ty: dy / distance,
        start: length,
        end,
      })
      length = end
    }
    x = next_x
    y = next_y
  }
  fn cubic(
    x0 : Double,
    y0 : Double,
    x1 : Double,
    y1 : Double,
    x2 : Double,
    y2 : Double,
    x3 : Double,
    y3 : Double,
    depth : Int32,
  ) -> Unit raise OraError {
    let a = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).sqrt()
    let b = ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).sqrt()
    let c = ((x3 - x2) * (x3 - x2) + (y3 - y2) * (y3 - y2)).sqrt()
    let chord = ((x3 - x0) * (x3 - x0) + (y3 - y0) * (y3 - y0)).sqrt()
    if depth >= 12 || a + b + c - chord <= 0.0005 {
      line(x3, y3)
    } else {
      let ax = (x0 + x1) / 2.0
      let ay = (y0 + y1) / 2.0
      let bx = (x1 + x2) / 2.0
      let by = (y1 + y2) / 2.0
      let cx = (x2 + x3) / 2.0
      let cy = (y2 + y3) / 2.0
      let dx = (ax + bx) / 2.0
      let dy = (ay + by) / 2.0
      let ex = (bx + cx) / 2.0
      let ey = (by + cy) / 2.0
      let mx = (dx + ex) / 2.0
      let my = (dy + ey) / 2.0
      cubic(x0, y0, ax, ay, dx, dy, mx, my, depth + 1)
      cubic(mx, my, ex, ey, cx, cy, x3, y3, depth + 1)
    }
  }
  fn quadratic(
    a : Double,
    b : Double,
    c : Double,
    d : Double,
  ) -> Unit raise OraError {
    cubic(
      x,
      y,
      (x + 2.0 * a) / 3.0,
      (y + 2.0 * b) / 3.0,
      (c + 2.0 * a) / 3.0,
      (d + 2.0 * b) / 3.0,
      c,
      d,
      0,
    )
  }
  fn arc(
    radius_x : Double,
    radius_y : Double,
    rotation : Double,
    large : Bool,
    sweep : Bool,
    next_x : Double,
    next_y : Double,
  ) -> Unit raise OraError {
    if x == next_x && y == next_y {
      return
    }
    let mut rx = radius_x.abs()
    let mut ry = radius_y.abs()
    if rx == 0.0 || ry == 0.0 {
      line(next_x, next_y)
      return
    }
    let phi = rotation * 3.141592653589793 / 180.0
    let cos_phi = @math.cos(phi)
    let sin_phi = @math.sin(phi)
    let dx = (x - next_x) / 2.0
    let dy = (y - next_y) / 2.0
    let px = cos_phi * dx + sin_phi * dy
    let py = -sin_phi * dx + cos_phi * dy
    let reach = px / rx * (px / rx) + py / ry * (py / ry)
    if reach > 1.0 {
      rx *= reach.sqrt()
      ry *= reach.sqrt()
    }
    let u = px / rx
    let v = py / ry
    let denom = u * u + v * v
    if denom == 0.0 || !denom.is_finite() {
      raise Unsupported("Invalid elliptical arc in SVG text path")
    }
    let sign = if large == sweep { -1.0 } else { 1.0 }
    let factor = sign * ((1.0 - denom).max(0.0) / denom).sqrt()
    let cx = factor * rx * v
    let cy = -factor * ry * u
    let center_x = cos_phi * cx - sin_phi * cy + (x + next_x) / 2.0
    let center_y = sin_phi * cx + cos_phi * cy + (y + next_y) / 2.0
    let start = @math.atan2((py - cy) / ry, (px - cx) / rx)
    let finish = @math.atan2((-py - cy) / ry, (-px - cx) / rx)
    let mut delta = finish - start
    let full = 6.283185307179586
    if sweep && delta < 0.0 {
      delta += full
    }
    if !sweep && delta > 0.0 {
      delta -= full
    }
    let steps = (delta.abs() * (rx.max(ry) / 0.008).sqrt())
      .ceil()
      .max(1.0)
      .min(4096.0)
      .to_int()
    for i in 1..<steps {
      let angle = start + delta * i.to_double() / steps.to_double()
      let ax = rx * @math.cos(angle)
      let ay = ry * @math.sin(angle)
      line(
        center_x + cos_phi * ax - sin_phi * ay,
        center_y + sin_phi * ax + cos_phi * ay,
      )
    }
    line(next_x, next_y)
  }
  for command in @vector.parse_path(path.attr("d").unwrap_or("")) {
    let previous = control
    control = None
    let absolute = match command {
      ArcToRel(rx, ry, rotation, large, sweep, a, b) =>
        @vector.ArcTo(rx, ry, rotation, large, sweep, x + a, y + b)
      CurveToRel(a, b, c, d, e, f) =>
        @vector.CurveTo(x + a, y + b, x + c, y + d, x + e, y + f)
      SmoothCurveToRel(a, b, c, d) =>
        @vector.SmoothCurveTo(x + a, y + b, x + c, y + d)
      QuadraticCurveToRel(a, b, c, d) =>
        @vector.QuadraticCurveTo(x + a, y + b, x + c, y + d)
      SmoothQuadraticCurveToRel(a, b) =>
        @vector.SmoothQuadraticCurveTo(x + a, y + b)
      other => other
    }
    match absolute {
      MoveTo(a, b) => {
        x = a
        y = b
        origin = (x, y)
      }
      MoveToRel(a, b) => {
        x += a
        y += b
        origin = (x, y)
      }
      LineTo(a, b) => line(a, b)
      LineToRel(a, b) => line(x + a, y + b)
      HorizontalLineTo(a) => line(a, y)
      HorizontalLineToRel(a) => line(x + a, y)
      VerticalLineTo(b) => line(x, b)
      VerticalLineToRel(b) => line(x, y + b)
      ClosePath => line(origin.0, origin.1)
      ArcTo(rx, ry, rotation, large, sweep, a, b) =>
        arc(rx, ry, rotation, large, sweep, a, b)
      CurveTo(a, b, c, d, e, f) => {
        cubic(x, y, a, b, c, d, e, f, 0)
        control = Some((c, d, true))
      }
      SmoothCurveTo(c, d, e, f) => {
        let (a, b) = match previous {
          Some((a, b, true)) => (2.0 * x - a, 2.0 * y - b)
          _ => (x, y)
        }
        cubic(x, y, a, b, c, d, e, f, 0)
        control = Some((c, d, true))
      }
      QuadraticCurveTo(a, b, c, d) => {
        quadratic(a, b, c, d)
        control = Some((a, b, false))
      }
      SmoothQuadraticCurveTo(c, d) => {
        let (a, b) = match previous {
          Some((a, b, false)) => (2.0 * x - a, 2.0 * y - b)
          _ => (x, y)
        }
        quadratic(a, b, c, d)
        control = Some((a, b, false))
      }
      _ => raise Unsupported("Unsupported curve in SVG text path")
    }
  }
  guard length > 0.0 else { raise Unsupported("SVG text path is empty") }
  let author_length = match path.attr("pathLength") {
    Some(value) => svg_number(value)
    None => length
  }
  guard author_length > 0.0 else {
    raise Unsupported("SVG text pathLength must be positive")
  }
  let distance_scale = length / author_length
  let start = element.attr("startOffset").unwrap_or("0")
  let offset = if start.has_suffix("%") {
    length * svg_number(start[:start.length() - 1].to_owned()) / 100.0
  } else {
    svg_dimension(start) * distance_scale
  }
  { segments, length, offset, distance_scale, }
}

///|
fn SvgTextPath::glyph_transform(
  self : SvgTextPath,
  x : Double,
  y : Double,
  advance : Double,
  scale : Double,
) -> String? {
  let half = advance / 2.0
  let middle = self.offset + (x + half) * self.distance_scale
  if middle < 0.0 || middle > self.length {
    return None
  }
  let mut low = 0
  let mut high = self.segments.length() - 1
  while low < high {
    let mid = (low + high) / 2
    if middle <= self.segments[mid].end {
      high = mid
    } else {
      low = mid + 1
    }
  }
  let segment = self.segments[low]
  let offset = middle - segment.start - half
  let px = segment.x + offset * segment.tx - y * segment.ty
  let py = segment.y + offset * segment.ty + y * segment.tx
  let values = [
    scale * segment.tx,
    scale * segment.ty,
    scale * segment.ty,
    -scale * segment.tx,
    px,
    py,
  ]
  Some("matrix(" + values.map(value => value.to_string()).join(" ") + ")")
}
