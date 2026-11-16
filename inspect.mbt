///|
fn inspect_tree(
  parent : @dom.Element,
  prefix : Array[Int32],
  depth : Int32,
) -> Json raise {
  if depth > 128 {
    raise InvalidDocument("Layer tree exceeds depth limit")
  }
  let nodes : Array[Json] = []
  for i, child in parent.child_elements() {
    let path = prefix.copy()
    path.push(i)
    let p = properties(child)
    nodes.push({
      "name": p.name,
      "path": path,
      "kind": if child.name == "stack" {
        "group"
      } else {
        "layer"
      },
      "element": child.name,
      "x": p.x,
      "y": p.y,
      "visible": p.visible,
      "opacity": p.opacity,
      "op": p.composite_op,
      "children": inspect_tree(child, path, depth + 1),
    })
  }
  Json::array(nodes)
}

///|
/// Inspect the document tree and archived preview without decoding layer pixels.
pub fn inspect(data : Bytes) -> Json raise {
  let entries = archive_entries(data)
  let xml = @xml.loads(@utf8.decode(resource(entries, "stack.xml")))
  let root = match xml.document_element() {
    Some(e) => e
    None => raise InvalidDocument("Missing image root")
  }
  if root.name != "image" {
    raise InvalidDocument("Expected image root")
  }
  let children = root.child_elements()
  if children.length() != 1 || children[0].name != "stack" {
    raise InvalidDocument("Expected one root stack")
  }
  let preview = resource(entries, "mergedimage.png")
  {
    "name": root.attr("name").unwrap_or("Untitled"),
    "width": int_attr(root, "w", 0),
    "height": int_attr(root, "h", 0),
    "tree": inspect_tree(children[0], [], 0),
    "png": @base64.encode(preview[:]),
  }
}
