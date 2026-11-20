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
fn reserve_svg_paths(nodes : Array[Node], paths : Map[String, Bool]) -> Unit {
  for node in nodes {
    match node {
      Layer(_, image) =>
        if image.vector_path is Some(path) {
          paths[path] = true
        }
      Group(_, _, children) => reserve_svg_paths(children, paths)
    }
  }
}

///|
fn write_nodes(
  nodes : Array[Node],
  entries : Array[@zip.Entry],
  depth : Int32,
  reserved : Map[String, Bool],
) -> Array[@dom.Node] raise {
  if depth > 128 {
    raise InvalidDocument("Layer tree exceeds depth limit")
  }
  let result : Array[@dom.Node] = []
  for node in nodes {
    match node {
      Layer(p, image) => {
        let (extension, payload) = match image.svg_source() {
          Some(source) => (".svg", source)
          None =>
            (
              ".png",
              match image.raster_source {
                Some(original) => original
                None => image.encode_png()
              },
            )
        }
        let mut serial = entries.length()
        let mut path = "data/moonopenraster-layer" +
          serial.to_string() +
          extension
        while reserved.contains(path) || entries.any(e => e.name == path) {
          serial += 1
          path = "data/moonopenraster-layer" + serial.to_string() + extension
        }
        if image.vector_path is Some(original) &&
          original != "mimetype" &&
          original != "stack.xml" &&
          original != "mergedimage.png" &&
          original != "Thumbnails/thumbnail.png" {
          guard !entries.any(e => e.name == original && e.data != payload) else {
            raise InvalidDocument("Conflicting SVG resource path: " + original)
          }
          path = original
        }
        if !entries.any(e => e.name == path) {
          entries.push(@zip.Entry::new(path, payload, kind=Stored))
        }
        let a = attrs(p)
        a.push(("src", path))
        result.push(ElementNode(@dom.Element::new("layer", attrs=a)))
      }
      Group(p, isolation, children) => {
        let a = attrs(p).filter(a => a.0 != "x" && a.0 != "y")
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
              children=write_nodes(children, entries, depth + 1, reserved),
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
    Some(p) => p.extra.copy()
  }
  let reserved : Map[String, Bool] = Map([])
  reserve_svg_paths(self.children, reserved)
  let stack = @dom.Element::new(
    "stack",
    attrs=root_props,
    children=write_nodes(self.children, entries, 0, reserved),
  )
  let root = @dom.Element::new(
    "image",
    attrs=[
      ("version", "0.0.6"),
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
    image.resize_nearest(w, h)
  }
  entries.push(
    @zip.Entry::new(
      "Thumbnails/thumbnail.png",
      thumb.as_preview().encode_png(),
      kind=Stored,
    ),
  )
  if entries.length() > 4096 {
    raise InvalidDocument("Output archive exceeds entry limit")
  }
  let mut total = 0L
  for entry in entries {
    if entry.data.length() > 67108864 {
      raise InvalidDocument("Output resource exceeds 64 MiB: " + entry.name)
    }
    total += entry.data.length().to_int64()
  }
  if total > 268435456L {
    raise InvalidDocument("Output resources exceed 256 MiB")
  }
  let data = @zip.zip(entries[:])
  if data.length() > 268435456 {
    raise InvalidDocument("Output archive exceeds 256 MiB")
  }
  data
}
