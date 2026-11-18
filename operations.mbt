///|
/// A detached copy of extension attributes. Standard attributes use typed setters.
pub fn Properties::extra(self : Properties) -> Array[(String, String)] {
  self.extra.copy()
}

///|
/// Replace extension attributes without permitting duplicate or reserved keys.
pub fn Document::replace_extra(
  self : Document,
  path : Array[Int32],
  attributes : Array[(String, String)],
) -> Document raise {
  let keys : Array[String] = []
  for (key, _) in attributes {
    let valid_name = !key.is_empty() &&
      key[:].all(c => {
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '_' ||
        c == '-' ||
        c == '.' ||
        c == ':'
      }) &&
      !((key.code_unit_at(0) >= 48 && key.code_unit_at(0) <= 57) ||
      key.has_prefix("-") ||
      key.has_prefix("."))
    if !valid_name ||
      [
        "name", "x", "y", "visibility", "opacity", "composite-op", "src", "isolation",
      ].contains(key) ||
      keys.contains(key) {
      raise InvalidDocument("Reserved or duplicate extension attribute: " + key)
    }
    keys.push(key)
  }
  let extra = attributes.copy()
  {
    ..self,
    children: change_at(self.children, path[:], node => {
      match node {
        Layer(p, i) => Layer({ ..p, extra, }, i)
        Group(p, s, c) => Group({ ..p, extra, }, s, c)
      }
    }),
  }
}

///|
fn find_node(
  nodes : Array[Node],
  path : ArrayView[Int32],
) -> Node raise OraError {
  if path.is_empty() || path[0] < 0 || path[0] >= nodes.length() {
    raise InvalidDocument("Invalid layer path")
  }
  let node = nodes[path[0]]
  if path.length() == 1 {
    return node
  }
  match node {
    Group(_, _, c) => find_node(c, path[1:])
    _ => raise InvalidDocument("Layer path traverses a raster layer")
  }
}

///|
/// Look up a node, detaching any mutable group arrays from the document.
pub fn Document::node(
  self : Document,
  path : Array[Int32],
) -> Node raise OraError {
  copy_node(find_node(self.children, path[:]))
}

///|
/// Duplicate immediately above the source, including group isolation and extensions.
pub fn Document::duplicate(
  self : Document,
  path : Array[Int32],
  name~ : String,
) -> Document raise {
  let node = find_node(self.children, path[:])
  let renamed = match node {
    Layer(p, i) => Layer({ ..p, name, }, i)
    Group(p, s, c) => Group({ ..p, name, }, s, c)
  }
  self.insert(
    path[:path.length() - 1].to_owned(),
    path[path.length() - 1],
    renamed,
  )
}

///|
/// Parent is resolved before removal; index addresses its list after removal.
/// Moving into the source or any of its descendants is rejected.
pub fn Document::move_to(
  self : Document,
  source : Array[Int32],
  parent : Array[Int32],
  index : Int32,
) -> Document raise {
  let node = find_node(self.children, source[:])
  let mut descendant = parent.length() >= source.length()
  for i in 0..<source.length().min(parent.length()) {
    if source[i] != parent[i] {
      descendant = false
    }
  }
  if descendant {
    raise InvalidDocument("Cannot move a group into itself")
  }
  if !parent.is_empty() {
    match find_node(self.children, parent[:]) {
      Group(_, _, _) => ()
      _ => raise InvalidDocument("Parent must be a group")
    }
  }
  let adjusted = parent.copy()
  let depth = source.length() - 1
  if parent.length() > depth {
    let mut siblings = true
    for i in 0..<depth {
      if source[i] != parent[i] {
        siblings = false
      }
    }
    if siblings && parent[depth] > source[depth] {
      adjusted[depth] -= 1
    }
  }
  self.remove(source).insert(adjusted, index, node)
}

///|
/// Export intrinsic raster pixels, without baking in offset, opacity or blending.
pub fn Document::layer_png(self : Document, path : Array[Int32]) -> Bytes raise {
  match find_node(self.children, path[:]) {
    Layer(_, image) => image.encode_png()
    _ => raise InvalidDocument("Expected raster layer")
  }
}

///|
fn export_layers(
  nodes : Array[Node],
  entries : Array[@zip.Entry],
  manifest : Array[Json],
  prefix : Array[Int32],
) -> Unit raise {
  for index, node in nodes {
    let path = prefix.copy()
    path.push(index)
    match node {
      Group(_, _, children) => export_layers(children, entries, manifest, path)
      Layer(p, image) => {
        let file = "layer-" + manifest.length().to_string() + ".png"
        entries.push(@zip.Entry::new(file, image.encode_png(), kind=Stored))
        manifest.push({
          "file": file,
          "name": p.name,
          "path": path,
          "x": p.x,
          "y": p.y,
          "opacity": p.opacity,
          "visible": p.visible,
          "op": p.composite_op,
        })
      }
    }
  }
}

///|
/// Flatten raster resources into safely named PNGs with a layers.json manifest.
pub fn Document::layers_zip(self : Document) -> Bytes raise {
  let entries = []
  let manifest = []
  export_layers(self.children, entries, manifest, [])
  entries.push(
    @zip.Entry::new(
      "layers.json",
      @utf8.encode(Json::array(manifest).stringify()),
      kind=Stored,
    ),
  )
  @zip.zip(entries[:])
}

///|
/// Resize for thumbnails and interactive previews; the source remains immutable.
pub fn Image::resize_nearest(
  self : Image,
  width : Int32,
  height : Int32,
) -> Image raise OraError {
  // Validate dimensions before multiplying or allocating.
  if width <= 0 ||
    height <= 0 ||
    width > 16384 ||
    height > 16384 ||
    width.to_int64() * height.to_int64() > 16777216 {
    raise InvalidDocument("Image dimensions exceed limits")
  }
  let bytes_per_pixel = self.bits / 2
  let pixels = Array::makei(width * height * bytes_per_pixel, i => {
    let x = i / bytes_per_pixel % width
    let y = i / bytes_per_pixel / width
    self.pixels[(y * self.height / height * self.width + x * self.width / width) *
    bytes_per_pixel +
    i % bytes_per_pixel]
  })
  { width, height, pixels, bits: self.bits, }
}

///|
/// Rendering is standards based; this operation can differ from Krita's Addition.
pub fn Document::compatibility_warnings(self : Document) -> Array[String] {
  fn has_plus(nodes : Array[Node]) -> Bool {
    nodes.any(node => {
      match node {
        Layer(p, _) => p.composite_op == "svg:plus"
        Group(p, _, c) => p.composite_op == "svg:plus" || has_plus(c)
      }
    })
  }
  if has_plus(self.children) {
    [
      "svg:plus uses W3C compositing; Krita Addition may display different pixels.",
    ]
  } else {
    []
  }
}
