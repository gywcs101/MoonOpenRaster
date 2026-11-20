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
    Some(s) => {
      let text = s[:].trim()
      let digits = if text.has_prefix("+") || text.has_prefix("-") {
        text[1:]
      } else {
        text
      }
      if digits.is_empty() || !digits.all(c => c >= '0' && c <= '9') {
        raise InvalidDocument("Expected integer attribute " + key + ": " + s)
      }
      // Accumulate with a checked bound before conversion, including long strings.
      let mut n = 0
      for c in digits {
        let digit = c.to_int() - 48
        if n > (2147483647 - digit) / 10 {
          raise InvalidDocument("Integer attribute out of range: " + key)
        }
        n = n * 10 + digit
      }
      if text.has_prefix("-") {
        -n
      } else {
        n
      }
    }
  }
}

///|
fn properties(e : @dom.Element) -> Properties raise {
  let opacity = match e.attr("opacity") {
    None => 1.0
    Some(s) => svg_number(s)
  }
  let p = Properties::new(
    e.attr("name").unwrap_or(""),
    x=int_attr(e, "x", 0),
    y=int_attr(e, "y", 0),
    visible=match e.attr("visibility").unwrap_or("visible") {
      "visible" => true
      "hidden" => false
      other => raise InvalidDocument("Unknown visibility: " + other)
    },
    opacity~,
    composite_op=e.attr("composite-op").unwrap_or("svg:src-over"),
  )
  let known = [
    "name", "x", "y", "visibility", "opacity", "composite-op", "src", "isolation",
  ]
  { ..p, extra: e.attrs.filter(a => !known.contains(a.0)), }
}

///|
fn isolation(e : @dom.Element) -> Isolation raise OraError {
  match e.attr("isolation").unwrap_or("isolate") {
    "isolate" => Isolate
    "auto" => Auto
    other => raise InvalidDocument("Unknown isolation: " + other)
  }
}

///|
fn parse_nodes(
  e : @dom.Element,
  entries : Array[(String, Bytes)],
  depth : Int32,
  decoded_bytes : Ref[Int64],
  retained : Map[String, Bool],
  viewport : (Int32, Int32),
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
        let payload = resource(entries, path)
        let image = if path.to_lower().has_suffix(".svg") {
          decode_svg_with_options(
            payload,
            svg_resource_options(path, entries, retained),
            Some(path),
            href => svg_archive_resource(path, entries, retained, href),
            viewport=Some(viewport),
          ) catch {
            Unsupported(message) => raise Unsupported(path + ": " + message)
            InvalidDocument(message) =>
              raise InvalidDocument(path + ": " + message)
            error => raise error
          }
        } else {
          decode_png(payload)
        }
        decoded_bytes.val = decoded_bytes.val + image.storage_bytes()
        if decoded_bytes.val > 134217728L {
          raise InvalidDocument("Decoded layer pixels exceed 128 MiB budget")
        }
        result.push(Layer(p, image))
      }
      "stack" =>
        result.push(
          Group(
            p,
            isolation(child),
            parse_nodes(
              child,
              entries,
              depth + 1,
              decoded_bytes,
              retained,
              viewport,
            ),
          ),
        )
      _ => raise Unsupported("Unknown layer element: " + child.name)
    }
  }
  result
}

///|
fn read_image_attributes(root : @dom.Element) -> Array[(String, String)] raise {
  let attributes = root.attrs.filter(a => {
    !["w", "h", "name", "version", "xres", "yres"].contains(a.0)
  })
  if root.has_attr("xres") || root.has_attr("yres") {
    let x = int_attr(root, "xres", 72)
    let y = int_attr(root, "yres", 72)
    if x < 1 || y < 1 {
      raise InvalidDocument("OpenRaster resolution must be positive")
    }
    attributes.push(("xres", x.to_string()))
    attributes.push(("yres", y.to_string()))
  }
  attributes
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
  let retained : Map[String, Bool] = Map([])
  let width = int_attr(root, "w", 0)
  let height = int_attr(root, "h", 0)
  check_image_size(width, height)
  let doc = Document::new(
    width,
    height,
    parse_nodes(children[0], entries, 0, Ref(0L), retained, (width, height)),
    name=root.attr("name").unwrap_or("Untitled"),
  )
  let layer_paths : Array[String] = []
  ignore(isolation(children[0]))
  collect_paths(children[0], layer_paths)
  {
    ..doc,
    root_properties: Some(properties(children[0])),
    image_attributes: read_image_attributes(root),
    resources: entries.filter(e => {
      (!layer_paths.contains(e.0) || retained.contains(e.0)) &&
      e.0 != "mimetype" &&
      e.0 != "stack.xml" &&
      e.0 != "mergedimage.png" &&
      e.0 != "Thumbnails/thumbnail.png"
    }),
  }
}

///|
fn collect_paths(e : @dom.Element, result : Array[String]) -> Unit {
  if e.name == "layer" {
    if e.attr("src") is Some(path) {
      result.push(path)
    }
  }
  for child in e.child_elements() {
    collect_paths(child, result)
  }
}
