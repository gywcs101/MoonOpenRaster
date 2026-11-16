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
  opacity : Double,
  depth : Int32,
) -> Unit raise OraError {
  if depth > 128 ||
    (depth + 2).to_int64() *
    canvas.width.to_int64() *
    canvas.height.to_int64() *
    4L >
    268435456L {
    raise InvalidDocument("Rendering buffer budget exceeded")
  }
  for i = nodes.length() - 1; i >= 0; i = i - 1 {
    match nodes[i] {
      Layer(p, image) =>
        if p.visible {
          paint(canvas, image, p.x, p.y, p.opacity * opacity, p.composite_op)
        }
      Group(p, isolation, children) =>
        if p.visible {
          match isolation {
            Auto =>
              render_nodes(children, canvas, opacity * p.opacity, depth + 1)
            Isolate => {
              let buffer = Image::new(
                canvas.width,
                canvas.height,
                Array::make(canvas.width * canvas.height * 4, 0),
              )
              render_nodes(children, buffer, 1.0, depth + 1)
              paint(canvas, buffer, 0, 0, p.opacity * opacity, p.composite_op)
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
  render_nodes(self.children, image, 1.0, 0)
  image
}
