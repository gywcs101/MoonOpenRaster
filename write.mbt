///|
fn attrs(p : Properties) -> Array[(String, String)] {
  let a = p.extra.copy()
  let values = [
    ("name", p.name),
    ("x", p.x.to_string()),
    ("y", p.y.to_string()),
    ("visibility", if p.visible { "visible" } else { "hidden" }),
    ("opacity", p.opacity.to_string()),
    ("composite-op", p.composite_op),
  ]
  for pair in values {
    a.push(pair)
  }
  a
}

///|
fn write_nodes(
  nodes : Array[Node],
  entries : Array[@zip.Entry],
  depth : Int32,
) -> Array[@dom.Node] raise {
  if depth > 128 {
    raise InvalidDocument("Layer tree exceeds depth limit")
  }
  let result : Array[@dom.Node] = []
  for node in nodes {
    match node {
      Layer(p, image) => {
        let path = "data/moonopenraster-layer" +
          entries.length().to_string() +
          ".png"
        entries.push(@zip.Entry::new(path, image.encode_png(), kind=Stored))
        let a = attrs(p)
        a.push(("src", path))
        result.push(ElementNode(@dom.Element::new("layer", attrs=a)))
      }
      Group(p, isolation, children) => {
        let a = attrs(p)
        a.push(
          (
            "isolation",
            match isolation {
              Auto => "auto"
              Isolate => "isolate"
            },
          ),
        )
        result.push(
          ElementNode(
            @dom.Element::new(
              "stack",
              attrs=a,
              children=write_nodes(children, entries, depth + 1),
            ),
          ),
        )
      }
    }
  }
  result
}

///|
pub fn Document::write(self : Document) -> Bytes raise {
  let entries = [@zip.Entry::new("mimetype", b"image/openraster", kind=Stored)]
  for (name, data) in self.resources {
    entries.push(@zip.Entry::new(name, data, kind=Stored))
  }
  let root_props = match self.root_properties {
    None => []
    Some(p) => attrs(p)
  }
  root_props.push(
    (
      "isolation",
      match self.root_isolation {
        Auto => "auto"
        Isolate => "isolate"
      },
    ),
  )
  let stack = @dom.Element::new(
    "stack",
    attrs=root_props,
    children=write_nodes(self.children, entries, 0),
  )
  let root = @dom.Element::new(
    "image",
    attrs=[
      ("version", "0.0.3"),
      ("w", self.width.to_string()),
      ("h", self.height.to_string()),
      ("name", self.name),
    ],
    children=[ElementNode(stack)],
  )
  for (key, value) in self.image_attributes {
    root.set_attr(key, value)
  }
  entries.push(
    @zip.Entry::new(
      "stack.xml",
      @utf8.encode(@dom.dumps(ElementNode(root))),
      kind=Stored,
    ),
  )
  let image = self.render()
  entries.push(
    @zip.Entry::new("mergedimage.png", image.encode_png(), kind=Stored),
  )
  let scale = 256.0 / self.width.max(self.height).to_double()
  let thumb = if scale >= 1.0 {
    image
  } else {
    let w = (self.width.to_double() * scale).to_int().max(1)
    let h = (self.height.to_double() * scale).to_int().max(1)
    let pixels : Array[Byte] = Array::make(w * h * 4, 0)
    for y in 0..<h {
      for x in 0..<w {
        for c in 0..<4 {
          pixels[(y * w + x) * 4 + c] = image.pixels[(
              y * self.height / h * self.width + x * self.width / w
            ) *
            4 +
            c]
        }
      }
    }
    Image::new(w, h, pixels)
  }
  entries.push(
    @zip.Entry::new("Thumbnails/thumbnail.png", thumb.encode_png(), kind=Stored),
  )
  @zip.zip(entries[:])
}
