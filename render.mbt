///|
fn paint(
  target : Image,
  source : Image,
  x : Int32,
  y : Int32,
  opacity : Double,
  op : String,
) -> Unit raise OraError {
  for ty in 0..<target.height {
    let sy = ty - y
    for tx in 0..<target.width {
      let sx = tx - x
      let b = (ty * target.width + tx) * 4
      let back = Array::makei(4, fn(i) {
        target.pixels[b + i].to_int().to_double() / 255.0
      })
      let front = if sx >= 0 &&
        sy >= 0 &&
        sx < source.width &&
        sy < source.height {
        let s = (sy * source.width + sx) * 4
        Array::makei(4, fn(i) {
          source.pixels[s + i].to_int().to_double() / 255.0
        })
      } else {
        [0.0, 0.0, 0.0, 0.0]
      }
      front[3] = front[3] * opacity
      let pixel = composite_pixel(back, front, op)
      for i in 0..<4 {
        target.pixels[b + i] = (pixel[i] * 255.0 + 0.5).to_int().to_byte()
      }
    }
  }
}

///|
fn render_nodes(
  nodes : Array[Node],
  canvas : Image,
  ox : Int32,
  oy : Int32,
  depth : Int32,
) -> Unit raise OraError {
  if depth > 128 {
    raise InvalidDocument("Layer tree exceeds depth limit")
  }
  for i = nodes.length() - 1; i >= 0; i = i - 1 {
    match nodes[i] {
      Layer(p, image) =>
        if p.visible {
          paint(canvas, image, ox + p.x, oy + p.y, p.opacity, p.composite_op)
        }
      Group(p, isolation, children) =>
        if p.visible {
          match isolation {
            Auto => {
              let before = canvas.pixels.copy()
              render_nodes(children, canvas, ox + p.x, oy + p.y, depth + 1)
              if p.opacity < 1.0 {
                for j in (0..<canvas.width) * canvas.height {
                  let b = j * 4
                  let a0 = before[b + 3].to_int().to_double() / 255.0
                  let a1 = canvas.pixels[b + 3].to_int().to_double() / 255.0
                  let a = a0 * (1.0 - p.opacity) + a1 * p.opacity
                  for k in 0..<3 {
                    let v = if a == 0.0 {
                      0.0
                    } else {
                      (
                        before[b + k].to_int().to_double() *
                        a0 *
                        (1.0 - p.opacity) +
                        canvas.pixels[b + k].to_int().to_double() *
                        a1 *
                        p.opacity
                      ) /
                      a
                    }
                    canvas.pixels[b + k] = (v + 0.5).to_int().to_byte()
                  }
                  canvas.pixels[b + 3] = (a * 255.0 + 0.5).to_int().to_byte()
                }
              }
            }
            Isolate => {
              let buffer = Image::new(
                canvas.width,
                canvas.height,
                Array::make(canvas.width * canvas.height * 4, 0),
              )
              render_nodes(children, buffer, ox + p.x, oy + p.y, depth + 1)
              paint(canvas, buffer, 0, 0, p.opacity, p.composite_op)
            }
          }
        }
    }
  }
}

///|
pub fn Document::render(self : Document) -> Image raise OraError {
  let image = Image::new(
    self.width,
    self.height,
    Array::make(self.width * self.height * 4, 0),
  )
  render_nodes(self.children, image, 0, 0, 0)
  image
}
