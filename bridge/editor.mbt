///|
let undo_stack : Ref[Array[(@ora.Document, Int32)]] = Ref([])

///|
let redo_stack : Ref[Array[(@ora.Document, Int32)]] = Ref([])

///|
let revision : Ref[Int32] = Ref(0)

///|
let next_revision : Ref[Int32] = Ref(1)

///|
let preview_cache : Ref[@ora.Document?] = Ref(None)

///|
fn reset_editor(doc : @ora.Document) -> Unit {
  current.val = Some(doc)
  undo_stack.val = []
  redo_stack.val = []
  revision.val = next_revision.val
  next_revision.val += 1
  preview_cache.val = None
}

///|
fn pixel_bytes(nodes : Array[@ora.Node]) -> Int64 {
  let mut size = 0L
  for node in nodes {
    size += match node {
      Layer(_, image) =>
        image.width().to_int64() * image.height().to_int64() * 4L
      Group(_, _, children) => pixel_bytes(children)
    }
  }
  size
}

///|
fn commit_document(old : @ora.Document, doc : @ora.Document) -> Json raise {
  // Render before changing any state: failed edits must be atomic.
  let response = snapshot(doc)
  let bytes = pixel_bytes(old.children())
    .max(pixel_bytes(doc.children()))
    .max(1L)
  let limit = (67108864L / bytes).to_int().max(1).min(20)
  undo_stack.val.push((old, revision.val))
  if undo_stack.val.length() > limit {
    undo_stack.val = undo_stack.val[undo_stack.val.length() - limit:].to_owned()
  }
  redo_stack.val = []
  current.val = Some(doc)
  revision.val = next_revision.val
  next_revision.val += 1
  preview_cache.val = None
  match response {
    Object(fields) => {
      fields["canUndo"] = true
      fields["canRedo"] = false
      fields["revision"] = Json::number(revision.val.to_double())
    }
    _ => ()
  }
  response
}

///|
fn indices(value : Json) -> Array[Int32] raise {
  match value {
    Array(values) =>
      values.map(v => {
        match v {
          Number(n, ..) => integer(n)
          _ => raise @ora.InvalidDocument("Invalid path")
        }
      })
    _ => raise @ora.InvalidDocument("Invalid path")
  }
}

///|
fn node_at(doc : @ora.Document, path : Array[Int32]) -> @ora.Node raise {
  let mut nodes = doc.children()
  let mut found : @ora.Node? = None
  for index in path {
    if index < 0 || index >= nodes.length() {
      raise @ora.InvalidDocument("Invalid layer path")
    }
    let node = nodes[index]
    found = Some(node)
    nodes = match node {
      Group(_, _, c) => c
      _ => []
    }
  }
  match found {
    Some(n) => n
    None => raise @ora.InvalidDocument("Select a layer first")
  }
}

///|
fn scaled_nodes(
  nodes : Array[@ora.Node],
  scale : Double,
) -> Array[@ora.Node] raise {
  nodes.map(node => {
    let (p, image, children, isolation) = match node {
      Layer(p, i) => (p, Some(i), [], @ora.Isolation::Isolate)
      Group(p, iso, c) => (p, None, c, iso)
    }
    let props = p
    match image {
      None => @ora.Node::Group(props, isolation, scaled_nodes(children, scale))
      Some(i) => {
        let w = (i.width().to_double() * scale).round().to_int().max(1)
        let h = (i.height().to_double() * scale).round().to_int().max(1)
        let source = i.pixels()
        let pixels = Array::makei(w * h * 4, n => {
          source[(
            n / 4 / w * i.height() / h * i.width() + n / 4 % w * i.width() / w
          ) *
          4 +
          n % 4]
        })
        @ora.Node::Layer(props, @ora.Image::new(w, h, pixels))
      }
    }
  })
}

///|
fn scale_offsets(
  doc : @ora.Document,
  nodes : Array[@ora.Node],
  prefix : Array[Int32],
  scale : Double,
) -> @ora.Document raise {
  let mut result = doc
  for index, node in nodes {
    let path = prefix.copy()
    path.push(index)
    let (p, children) = match node {
      Layer(p, _) => (p, [])
      Group(p, _, c) => (p, c)
    }
    result = result.set_properties(
      path,
      @ora.Properties::new(
        p.name,
        x=(p.x.to_double() * scale).round().to_int(),
        y=(p.y.to_double() * scale).round().to_int(),
        visible=p.visible,
        opacity=p.opacity,
        composite_op=p.composite_op,
      ),
    )
    result = scale_offsets(result, children, path, scale)
  }
  result
}

///|
fn export_layers(
  nodes : Array[@ora.Node],
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
fn preview_document(doc : @ora.Document) -> @ora.Document raise {
  let scale = (384.0 / doc.width().max(doc.height()).to_double()).min(1.0)
  match preview_cache.val {
    Some(d) => d
    None => {
      let d = @ora.Document::new(
        (doc.width().to_double() * scale).round().to_int().max(1),
        (doc.height().to_double() * scale).round().to_int().max(1),
        scaled_nodes(doc.children(), scale),
      )
      let adjusted = scale_offsets(d, d.children(), [], scale)
      preview_cache.val = Some(adjusted)
      adjusted
    }
  }
}

///|
fn editor_request(
  doc : @ora.Document,
  query : Json,
  action : String,
) -> Json raise {
  match (action, query) {
    ("warm-preview", _) => {
      ignore(preview_document(doc))
      { "ok": true }
    }
    ("undo" | "redo", _) => {
      let stack = if action == "undo" { undo_stack } else { redo_stack }
      let other = if action == "undo" { redo_stack } else { undo_stack }
      if stack.val.is_empty() {
        raise @ora.InvalidDocument("No history available")
      }
      let (previous, id) = stack.val[stack.val.length() - 1]
      let response = snapshot(previous)
      other.val.push((doc, revision.val))
      stack.val = stack.val[:stack.val.length() - 1].to_owned()
      current.val = Some(previous)
      revision.val = id
      preview_cache.val = None
      match response {
        Object(fields) => {
          fields["canUndo"] = Json::boolean(!undo_stack.val.is_empty())
          fields["canRedo"] = Json::boolean(!redo_stack.val.is_empty())
          fields["revision"] = Json::number(id.to_double())
        }
        _ => ()
      }
      response
    }
    ("preview", { "path": path, "x": Number(x, ..), "y": Number(y, ..), .. }) => {
      let scale = (384.0 / doc.width().max(doc.height()).to_double()).min(1.0)
      let small = preview_document(doc)
      let path = indices(path)
      let props = match node_at(small, path) {
        Layer(p, _) => p
        _ => raise @ora.InvalidDocument("Expected raster layer")
      }
      let moved = small.set_properties(
        path,
        @ora.Properties::new(
          props.name,
          x=(integer(x).to_double() * scale).round().to_int(),
          y=(integer(y).to_double() * scale).round().to_int(),
          visible=props.visible,
          opacity=props.opacity,
          composite_op=props.composite_op,
        ),
      )
      let image = moved.render()
      let pixels = Bytes::from_array(image.pixels())
      {
        "ok": true,
        "width": image.width(),
        "height": image.height(),
        "rgba": @base64.encode(pixels[:]),
      }
    }
    ("layer-png", { "path": path, .. }) => {
      let png = match node_at(doc, indices(path)) {
        Layer(_, i) => i.encode_png()
        _ => raise @ora.InvalidDocument("Expected raster layer")
      }
      { "ok": true, "data": @base64.encode(png[:]) }
    }
    ("layers-zip", _) => {
      let entries = []
      let manifest = []
      export_layers(doc.children(), entries, manifest, [])
      entries.push(
        @zip.Entry::new(
          "layers.json",
          @utf8.encode(Json::array(manifest).stringify()),
          kind=Stored,
        ),
      )
      let bytes = @zip.zip(entries[:])
      { "ok": true, "data": @base64.encode(bytes[:]) }
    }
    ("replace", { "path": path, "data": String(data), .. }) =>
      commit_document(
        doc,
        doc.replace_image(indices(path), @ora.decode_png(@base64.decode(data))),
      )
    (
      "insert",
      {
        "parent": parent,
        "index": Number(index, ..),
        "name": String(name),
        "data": String(data),
        ..
      },
    ) =>
      commit_document(
        doc,
        doc.insert(
          indices(parent),
          integer(index),
          @ora.Node::Layer(
            @ora.Properties::new(name),
            @ora.decode_png(@base64.decode(data)),
          ),
        ),
      )
    (
      "group",
      { "parent": parent, "index": Number(index, ..), "name": String(name), .. },
    ) =>
      commit_document(
        doc,
        doc.insert(
          indices(parent),
          integer(index),
          @ora.Node::Group(@ora.Properties::new(name), Isolate, []),
        ),
      )
    ("duplicate", { "path": path, .. }) => {
      let path = indices(path)
      let node = node_at(doc, path)
      let p = match node {
        Layer(p, _) => p
        Group(p, _, _) => p
      }
      let copied = doc.insert(
        path[:path.length() - 1].to_owned(),
        path[path.length() - 1],
        node,
      )
      let named = copied.set_properties(
        path,
        @ora.Properties::new(
          p.name + " 副本",
          x=p.x,
          y=p.y,
          visible=p.visible,
          opacity=p.opacity,
          composite_op=p.composite_op,
        ),
      )
      commit_document(doc, named)
    }
    ("move", { "path": path, "parent": parent, .. }) => {
      let from = indices(path)
      let dest = indices(parent)
      let mut is_descendant = dest.length() >= from.length()
      for i in 0..<from.length().min(dest.length()) {
        if from[i] != dest[i] {
          is_descendant = false
        }
      }
      if is_descendant {
        raise @ora.InvalidDocument("Cannot move a group into itself")
      }
      let node = node_at(doc, from)
      // Resolve destination in the original tree, then adjust after removing a preceding sibling.
      if !dest.is_empty() {
        match node_at(doc, dest) {
          Group(_, _, _) => ()
          _ => raise @ora.InvalidDocument("Parent must be a group")
        }
      }
      let adjusted = dest.copy()
      let depth = from.length() - 1
      if dest.length() > depth {
        let mut same_parent = true
        for i in 0..<depth {
          if from[i] != dest[i] {
            same_parent = false
          }
        }
        if same_parent && dest[depth] > from[depth] {
          adjusted[depth] -= 1
        }
      }
      commit_document(doc, doc.remove(from).insert(adjusted, 0, node))
    }
    _ => raise @ora.InvalidDocument("Invalid editor request")
  }
}
