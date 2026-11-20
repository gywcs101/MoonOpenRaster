///|
priv struct SvgReferencedDocument {
  path : String
  ids : Map[String, @dom.Element]
}

///|
fn svg_text_reference_index(
  root : @dom.Element,
  path : String,
) -> SvgReferencedDocument {
  let ids : Map[String, @dom.Element] = Map([])
  fn visit(node : @dom.Element) -> Unit {
    if node.attr("id") is Some(id) {
      ids[id] = node
    }
    for child in node.child_elements() {
      visit(child)
    }
  }
  visit(root)
  { path, ids, }
}

///|
fn expand_svg_text_references(
  root : @dom.Element,
  path : String,
  load : (String) -> Bytes?,
) -> Bool raise {
  let source = svg_text_reference_index(root, path)
  let documents : Map[String, SvgReferencedDocument] = Map([(path, source)])
  let active : Map[String, Bool] = Map([])
  let mut changed = false
  let mut expanded = 0
  fn fetch(
    node : @dom.Element,
    document : SvgReferencedDocument,
    output : StringBuilder,
  ) -> Unit raise {
    let href = node
      .attr("href")
      .unwrap_or(node.attr("{http://www.w3.org/1999/xlink}href").unwrap_or(""))
    guard href.find("#") is Some(separator) &&
      svg_unescape(href[separator + 1:].to_owned(), path=false)
      is Some(fragment) &&
      !fragment.is_empty() else {
      raise Unsupported("SVG text reference requires a target id: " + href)
    }
    let related = if separator == 0 {
      document
    } else {
      guard svg_archive_path(document.path, href[:separator].to_owned())
        is Some(location) else {
        raise Unsupported("Invalid SVG text reference: " + href)
      }
      match documents.get(location) {
        Some(cached) => cached
        None => {
          guard documents.length() < 8 &&
            load(svg_archive_uri(location)) is Some(bytes) else {
            raise Unsupported(
              "Missing or excessive SVG text reference: " + href,
            )
          }
          let (_, root) = svg_parse_source(bytes)
          let related = svg_text_reference_index(root, location)
          documents[location] = related
          related
        }
      }
    }
    let key = related.path + "#" + fragment
    guard active.length() < 16 && !active.contains(key) else {
      raise Unsupported("Circular SVG text reference: " + href)
    }
    guard related.ids.get(fragment) is Some(target) else {
      raise Unsupported("Unresolved SVG text reference: " + href)
    }
    active[key] = true
    fn copy(element : @dom.Element) -> Unit raise {
      match @dom.local_of(element.name) {
        "tref" => fetch(element, related, output)
        "metadata" | "title" | "desc" => ()
        _ => {
          let container : @dom.Node = ElementNode(element)
          for child in container.children() {
            match child {
              TextNode(text) | CDataNode(text) => {
                expanded += text.length()
                guard expanded <= 262144 else {
                  raise Unsupported(
                    "Expanded SVG text references exceed the rendering budget",
                  )
                }
                output.write_string(text)
              }
              ElementNode(element) => copy(element)
              _ => ()
            }
          }
        }
      }
    }
    copy(target)
    ignore(active.remove(key))
  }
  fn expand(element : @dom.Element) -> Unit raise {
    if @dom.local_of(element.name) == "tref" {
      let output = StringBuilder()
      fetch(element, source, output)
      element.set_text(output.to_string())
      changed = true
    } else {
      for child in element.child_elements() {
        expand(child)
      }
    }
  }
  expand(root)
  changed
}
