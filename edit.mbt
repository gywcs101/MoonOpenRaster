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
  {
    ..self,
    children: change_at(self.children, path[:], n => {
      match n {
        Layer(p, _) => Layer(p, image)
        Group(_, _, _) => raise InvalidDocument("Expected raster layer")
      }
    }),
  }
}

///|
pub fn Document::replace_children(
  self : Document,
  children : Array[Node],
) -> Document raise OraError {
  Document::new(
    self.width,
    self.height,
    children.map(copy_node),
    name=self.name,
  )
}
