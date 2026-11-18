///|
fn paint(
  target : Image,
  source : Image,
  x : Int32,
  y : Int32,
  opacity : Double,
  op : String,
  preserve_alpha~ : Bool = false,
) -> Unit raise OraError {
  // Validate once, then avoid allocating channel arrays for each separable pixel.
  ignore(composite_pixel([0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], op))
  let src_max = if source.bits == 8 { 255.0 } else { 65535.0 }
  let dst_max = if target.bits == 8 { 255.0 } else { 65535.0 }
  let promote = if source.bits != target.bits { 257 } else { 1 }
  let full_canvas = op == "svg:dst-in" || op == "svg:dst-atop"
  let left = if full_canvas { 0 } else { x.max(0).min(target.width) }
  let top = if full_canvas { 0 } else { y.max(0).min(target.height) }
  let right = if full_canvas {
    target.width
  } else {
    (x + source.width).max(0).min(target.width)
  }
  let bottom = if full_canvas {
    target.height
  } else {
    (y + source.height).max(0).min(target.height)
  }
  let nonseparable = op == "svg:hue" ||
    op == "svg:saturation" ||
    op == "svg:color" ||
    op == "svg:luminosity"
  for ty in top..<bottom {
    let sy = ty - y
    for tx in left..<right {
      let sx = tx - x
      let b = (ty * target.width + tx) * 4
      let inside = sx >= 0 && sy >= 0 && sx < source.width && sy < source.height
      let s = if inside { (sy * source.width + sx) * 4 } else { 0 }
      let a = if inside {
        source.sample(s + 3).to_double() / src_max * opacity
      } else {
        0.0
      }
      let ab = target.sample(b + 3).to_double() / dst_max
      if a == 0.0 && !full_canvas {
        continue
      }
      if preserve_alpha && ab == 0.0 {
        continue
      }
      if op == "svg:src-over" && !preserve_alpha {
        let alpha = a + ab * (1.0 - a)
        if a == 1.0 || ab == 0.0 {
          for i in 0..<3 {
            target.put_sample(b + i, source.sample(s + i) * promote)
          }
        } else {
          for i in 0..<3 {
            let cb = target.sample(b + i).to_double() / dst_max
            let cs = source.sample(s + i).to_double() / src_max
            // Keep the same operation order as the independent pixel oracle.
            let blended = (1.0 - ab) * cs + ab * cs
            let value = ((a * blended + ab * (1.0 - a) * cb).min(1.0) / alpha)
              .max(0.0)
              .min(1.0)
            target.put_sample(b + i, (value * dst_max + 0.5).to_int())
          }
        }
        target.put_sample(b + 3, (alpha * dst_max + 0.5).to_int())
        continue
      }
      if nonseparable {
        let back = Array::makei(4, i => {
          target.sample(b + i).to_double() / dst_max
        })
        let front = Array::makei(4, i => {
          if inside {
            source.sample(s + i).to_double() / src_max
          } else {
            0.0
          }
        })
        front[3] = a
        let pixel = composite_pixel(back, front, op)
        if preserve_alpha {
          let blend = match op {
            "svg:hue" => set_lum(set_sat(front, sat(back)), lum(back))
            "svg:saturation" => set_lum(set_sat(back, sat(front)), lum(back))
            "svg:color" => set_lum(front, lum(back))
            _ => set_lum(back, lum(front))
          }
          for i in 0..<3 {
            pixel[i] = if ab > 0.0 {
              (1.0 - a) * back[i] + a * blend[i]
            } else {
              0.0
            }
          }
          pixel[3] = ab
        }
        for i in 0..<4 {
          target.put_sample(b + i, (pixel[i] * dst_max + 0.5).to_int())
        }
      } else {
        let (fa, fb) = match op {
          "svg:dst-in" => (0.0, a)
          "svg:dst-out" => (0.0, 1.0 - a)
          "svg:src-atop" => (ab, 1.0 - a)
          "svg:dst-atop" => (1.0 - ab, a)
          "svg:plus" => (1.0, 1.0)
          _ => (1.0, 1.0 - a)
        }
        let alpha = (a * fa + ab * fb).min(1.0)
        for i in 0..<3 {
          let cb = target.sample(b + i).to_double() / dst_max
          let cs = if inside {
            source.sample(s + i).to_double() / src_max
          } else {
            0.0
          }
          let blended = if op == "svg:plus" ||
            op == "svg:dst-in" ||
            op == "svg:dst-out" ||
            op == "svg:src-atop" ||
            op == "svg:dst-atop" {
            cs
          } else {
            (1.0 - ab) * cs + ab * channel(cb, cs, op)
          }
          let value = if preserve_alpha {
            if ab > 0.0 {
              ((1.0 - a) * cb + a * channel(cb, cs, op)).max(0.0).min(1.0)
            } else {
              0.0
            }
          } else if alpha > 0.0 {
            ((a * fa * blended + ab * fb * cb).min(1.0) / alpha)
            .max(0.0)
            .min(1.0)
          } else {
            0.0
          }
          target.put_sample(b + i, (value * dst_max + 0.5).to_int())
        }
        target.put_sample(
          b + 3,
          ((if preserve_alpha { ab } else { alpha }) * dst_max + 0.5).to_int(),
        )
      }
    }
  }
}

///|
fn render_nodes(
  nodes : Array[Node],
  canvas : Image,
  opacity : Double,
  depth : Int32,
) -> Unit raise OraError {
  if depth > 128 ||
    (depth + 2).to_int64() *
    canvas.width.to_int64() *
    canvas.height.to_int64() *
    (canvas.bits / 2).to_int64() >
    268435456L {
    raise InvalidDocument("Rendering buffer budget exceeded")
  }
  for i = nodes.length() - 1; i >= 0; i = i - 1 {
    match nodes[i] {
      Layer(p, image) =>
        if p.visible {
          paint(
            canvas,
            image,
            p.x,
            p.y,
            p.opacity * opacity,
            p.composite_op,
            preserve_alpha=p.extra.contains(("alpha-preserve", "true")),
          )
        }
      Group(p, isolation, children) =>
        if p.visible {
          match isolation {
            Auto =>
              render_nodes(children, canvas, opacity * p.opacity, depth + 1)
            Isolate => {
              let buffer = blank_image(canvas.width, canvas.height, canvas.bits)
              render_nodes(children, buffer, 1.0, depth + 1)
              paint(
                canvas,
                buffer,
                0,
                0,
                p.opacity * opacity,
                p.composite_op,
                preserve_alpha=p.extra.contains(("alpha-preserve", "true")),
              )
            }
          }
        }
    }
  }
}

///|
pub fn Document::render(self : Document) -> Image raise OraError {
  let image = blank_image(self.width, self.height, self.bit_depth())
  render_nodes(self.children, image, 1.0, 0)
  image
}
