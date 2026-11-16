///|
fn parse_number(s : String) -> Double raise {
  match @json.parse(s) {
    Number(n, ..) => n
    _ => raise InvalidDocument("Expected number: " + s)
  }
}

///|
fn int_attr(e : @dom.Element, key : String, fallback : Int32) -> Int32 raise {
  match e.attr(key) {
    None => fallback
    Some(s) => parse_number(s).to_int()
  }
}

///|
fn properties(e : @dom.Element) -> Properties raise {
  let opacity = match e.attr("opacity") {
    None => 1.0
    Some(s) => parse_number(s)
  }
  Properties::new(
    e.attr("name").unwrap_or(""),
    x=int_attr(e, "x", 0),
    y=int_attr(e, "y", 0),
    visible=e.attr("visibility").unwrap_or("visible") == "visible",
    opacity~,
    composite_op=e.attr("composite-op").unwrap_or("svg:src-over"),
  )
}

///|
fn parse_nodes(
  e : @dom.Element,
  entries : Array[(String, Bytes)],
  depth : Int32,
) -> Array[Node] raise {
  if depth > 128 {
    raise InvalidDocument("Layer tree exceeds depth limit")
  }
  let result : Array[Node] = []
  for child in e.child_elements() {
    let p = properties(child)
    match child.name {
      "layer" => {
        let path = match child.attr("src") {
          Some(s) => s
          None => raise InvalidDocument("Layer is missing src")
        }
        result.push(Layer(p, decode_png(resource(entries, path))))
      }
      "stack" =>
        result.push(
          Group(
            p,
            if child.attr("isolation").unwrap_or("auto") == "isolate" {
              Isolate
            } else {
              Auto
            },
            parse_nodes(child, entries, depth + 1),
          ),
        )
      _ => raise Unsupported("Unknown layer element: " + child.name)
    }
  }
  result
}

///|
pub fn read(data : Bytes) -> Document raise {
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
  Document::new(
    int_attr(root, "w", 0),
    int_attr(root, "h", 0),
    parse_nodes(children[0], entries, 0),
    name=root.attr("name").unwrap_or("Untitled"),
  )
}
