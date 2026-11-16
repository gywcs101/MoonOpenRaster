///|
let current : Ref[@ora.Document?] = Ref(None)

///|
fn tree(nodes : Array[@ora.Node], prefix : Array[Int32]) -> Json {
  let result : Array[Json] = []
  for i, node in nodes {
    let path = prefix.copy()
    path.push(i)
    let (p, children, kind) = match node {
      Layer(p, _) => (p, [], "layer")
      Group(p, _, c) => (p, c, "group")
    }
    result.push({
      "name": p.name,
      "path": path,
      "x": p.x,
      "y": p.y,
      "opacity": p.opacity,
      "visible": p.visible,
      "op": p.composite_op,
      "kind": kind,
      "children": tree(children, path),
    })
  }
  Json::array(result)
}

///|
fn snapshot(doc : @ora.Document) -> Json raise {
  let png = doc.render().encode_png()
  {
    "ok": true,
    "width": doc.width(),
    "height": doc.height(),
    "name": doc.name(),
    "tree": tree(doc.children(), []),
    "png": @base64.encode(png[:]),
  }
}

///|
fn sample() -> @ora.Document raise {
  let w = 480
  let h = 360
  let background = Array::makei(w * h * 4, fn(i) {
    let c = i % 4
    if c == 3 {
      (255).to_byte()
    } else {
      let y = i / (w * 4)
      (if c == 0 {
        24 + y / 9
      } else if c == 1 {
        36 + y / 5
      } else {
        55 + y / 4
      }).to_byte()
    }
  })
  let shape = Array::makei(160 * 160 * 4, fn(i) {
    let c = i % 4
    let x = i / 4 % 160 - 80
    let y = i / (160 * 4) - 80
    if c == 3 {
      (if x * x + y * y < 6200 { 255 } else { 0 }).to_byte()
    } else {
      (if c == 0 { 222 } else if c == 1 { 168 } else { 99 }).to_byte()
    }
  })
  @ora.Document::new(
    w,
    h,
    [
      Group(@ora.Properties::new("Light study"), Isolate, [
        Layer(
          @ora.Properties::new("Amber", x=95, y=65),
          @ora.Image::new(160, 160, shape),
        ),
        Layer(
          @ora.Properties::new(
            "Echo",
            x=210,
            y=140,
            opacity=0.6,
            composite_op="svg:screen",
          ),
          @ora.Image::new(160, 160, shape),
        ),
      ]),
      Layer(@ora.Properties::new("Slate"), @ora.Image::new(w, h, background)),
    ],
    name="Light study",
  )
}

///|
pub fn request(input : String) -> String {
  try {
    let query = @json.parse(input)
    match query {
      { "action": "sample", .. } => {
        let d = sample()
        current.val = Some(d)
        snapshot(d).stringify()
      }
      { "action": "open", "data": String(s), .. } => {
        let d = @ora.read(@base64.decode(s))
        let response = snapshot(d)
        current.val = Some(d)
        response.stringify()
      }
      _ => {
        let doc = match current.val {
          Some(d) => d
          None => raise @ora.InvalidDocument("Open a document first")
        }
        match query {
          {
            "action": "edit",
            "path": Array(path),
            "name": String(name),
            "x": Number(x, ..),
            "y": Number(y, ..),
            "opacity": Number(opacity, ..),
            "visible": visible,
            "op": String(op),
            ..
          } => {
            let indices = path.map(v => {
              match v {
                Number(n, ..) => n.to_int()
                _ => raise @ora.InvalidDocument("Invalid path")
              }
            })
            let d = doc.set_properties(
              indices,
              @ora.Properties::new(
                name,
                x=x.to_int(),
                y=y.to_int(),
                opacity~,
                visible=match visible {
                  True => true
                  _ => false
                },
                composite_op=op,
              ),
            )
            let response = snapshot(d)
            current.val = Some(d)
            response.stringify()
          }
          { "action": "export", .. } => {
            let bytes = doc.write()
            let result : Json = { "ok": true, "data": @base64.encode(bytes[:]) }
            result.stringify()
          }
          _ => raise @ora.InvalidDocument("Unknown request")
        }
      }
    }
  } catch {
    e => {
      let result : Json = {
        "ok": false,
        "error": match e {
          @ora.InvalidDocument(s) => "Invalid document: " + s
          @ora.Unsupported(s) => "Unsupported feature: " + s
          _ => e.to_string()
        },
      }
      result.stringify()
    }
  }
}
