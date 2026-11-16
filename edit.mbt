///|
fn copy_node(node : Node) -> Node {
  match node {
    Layer(p, i) =>
      Layer(p, { width: i.width, height: i.height, pixels: i.pixels.copy(), })
    Group(p, s, c) => Group(p, s, c.map(copy_node))
  }
}

///|
fn change_at(
  nodes : Array[Node],
  path : ArrayView[Int32],
  change : (Node) -> Node raise,
) -> Array[Node] raise {
  if path.length() == 0 || path[0] < 0 || path[0] >= nodes.length() {
    raise InvalidDocument("Invalid layer path")
  }
  validate_nodes(nodes, 0, Ref(0L), Ref(0))
  let result = nodes.map(copy_node)
  let index = path[0]
  if path.length() == 1 {
    result[index] = change(result[index])
  } else {
    match result[index] {
      Layer(_, _) =>
        raise InvalidDocument("Layer path traverses a raster layer")
      Group(p, s, c) =>
        result[index] = Group(p, s, change_at(c, path[1:], change))
    }
  }
  result
}

///|
pub fn Document::set_properties(
  self : Document,
  path : Array[Int32],
  properties : Properties,
) -> Document raise {
  let p = Properties::new(
    properties.name,
    x=properties.x,
    y=properties.y,
    visible=properties.visible,
    opacity=properties.opacity,
    composite_op=properties.composite_op,
  )
  {
    ..self,
    children: change_at(self.children, path[:], n => {
      match n {
        Layer(old, i) => Layer({ ..p, extra: old.extra.copy(), }, i)
        Group(old, s, c) => Group({ ..p, extra: old.extra.copy(), }, s, c)
      }
    }),
  }
}

///|
pub fn Document::replace_image(
  self : Document,
  path : Array[Int32],
  image : Image,
) -> Document raise {
  checked_document(
    self,
    change_at(self.children, path[:], n => {
      match n {
        Layer(p, _) => Layer(p, image)
        Group(_, _, _) => raise InvalidDocument("Expected raster layer")
      }
    }),
  )
}

///|
pub fn Document::replace_children(
  self : Document,
  children : Array[Node],
) -> Document raise OraError {
  checked_document(self, children)
}

///|
fn checked_document(
  document : Document,
  children : Array[Node],
) -> Document raise OraError {
  validate_nodes(children, 0, Ref(0L), Ref(0))
  { ..document, children: children.map(copy_node), }
}

///|
fn edit_children(
  document : Document,
  parent : Array[Int32],
  edit : (Array[Node]) -> Array[Node] raise,
) -> Document raise {
  if parent.is_empty() {
    return checked_document(document, edit(document.children.map(copy_node)))
  }
  checked_document(
    document,
    change_at(document.children, parent[:], node => {
      match node {
        Group(p, s, c) => Group(p, s, edit(c))
        Layer(_, _) => raise InvalidDocument("Parent must be a group")
      }
    }),
  )
}

///|
pub fn Document::insert(
  self : Document,
  parent : Array[Int32],
  index : Int32,
  node : Node,
) -> Document raise {
  validate_nodes([node], 0, Ref(0L), Ref(0))
  edit_children(self, parent, children => {
    if index < 0 || index > children.length() {
      raise InvalidDocument("Insertion index out of range")
    }
    let result : Array[Node] = []
    for i in 0..<(children.length() + 1) {
      if i == index {
        result.push(copy_node(node))
      }
      if i < children.length() {
        result.push(children[i])
      }
    }
    result
  })
}

///|
pub fn Document::remove(self : Document, path : Array[Int32]) -> Document raise {
  if path.is_empty() {
    raise InvalidDocument("Cannot remove document root")
  }
  let index = path[path.length() - 1]
  edit_children(self, path[:path.length() - 1].to_owned(), children => {
    if index < 0 || index >= children.length() {
      raise InvalidDocument("Removal index out of range")
    }
    let result : Array[Node] = []
    for i, node in children {
      if i != index {
        result.push(node)
      }
    }
    result
  })
}

///|
pub fn Document::reorder(
  self : Document,
  path : Array[Int32],
  index : Int32,
) -> Document raise {
  if path.is_empty() {
    raise InvalidDocument("Cannot reorder document root")
  }
  let from = path[path.length() - 1]
  edit_children(self, path[:path.length() - 1].to_owned(), children => {
    if index < 0 ||
      index >= children.length() ||
      from < 0 ||
      from >= children.length() {
      raise InvalidDocument("Reorder index out of range")
    }
    let moved = children[from]
    let result : Array[Node] = []
    for i, node in children {
      if i != from {
        result.push(node)
      }
    }
    let output : Array[Node] = []
    for i in 0..<children.length() {
      if i == index {
        output.push(moved)
      }
      if i < result.length() {
        output.push(result[i])
      }
    }
    output
  })
}
