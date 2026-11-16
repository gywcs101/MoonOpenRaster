///|
fn integer(value : Double) -> Int32 raise @ora.OraError {
  if value.is_nan() ||
    value < -1000000.0 ||
    value > 1000000.0 ||
    value.to_int().to_double() != value {
    raise @ora.InvalidDocument("Expected an integer coordinate or layer index")
  }
  value.to_int()
}

///|
let original_source : Ref[Bytes?] = Ref(None)

///|
let current : Ref[@ora.Document?] = Ref(None)

///|
fn tree(nodes : Array[@ora.Node], prefix : Array[Int32]) -> Json raise {
  let result : Array[Json] = []
  for i, node in nodes {
    let path = prefix.copy()
    path.push(i)
    let (p, children, kind) = match node {
      Layer(p, _) => (p, [], "layer")
      Group(p, _, c) => (p, c, "group")
    }
    let preview = match node {
      Layer(_, image) => thumbnail(image)
      Group(_, _, _) => ""
    }
    let (width, height) = match node {
      Layer(_, image) => (image.width(), image.height())
      Group(_, _, _) => (0, 0)
    }
    result.push({
      "thumbnail": preview,
      "width": width,
      "height": height,
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
fn thumbnail(image : @ora.Image) -> String raise {
  let w = image.width()
  let h = image.height()
  let scale = 40.0 / w.max(h).to_double()
  let tw = (w.to_double() * scale).to_int().max(1)
  let th = (h.to_double() * scale).to_int().max(1)
  let source = image.pixels()
  let target : Array[Byte] = Array::make(tw * th * 4, 0)
  for y in 0..<th {
    for x in 0..<tw {
      for c in 0..<4 {
        target[(y * tw + x) * 4 + c] = source[(y * h / th * w + x * w / tw) * 4 +
          c]
      }
    }
  }
  let png = @ora.Image::new(tw, th, target).encode_png()
  @base64.encode(png[:])
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
      Group(@ora.Properties::new("光影叠层示例"), Isolate, [
        Layer(
          @ora.Properties::new("金色圆", x=95, y=65),
          @ora.Image::new(160, 160, shape),
        ),
        Layer(
          @ora.Properties::new(
            "半透明圆",
            x=210,
            y=140,
            opacity=0.6,
            composite_op="svg:screen",
          ),
          @ora.Image::new(160, 160, shape),
        ),
      ]),
      Layer(
        @ora.Properties::new("渐变背景"),
        @ora.Image::new(w, h, background),
      ),
    ],
    name="光影叠层示例",
  )
}

///|
pub fn request(input : String) -> String {
  try {
    let query = @json.parse(input)
    match query {
      {
        "action": "compose",
        "width": Number(w, ..),
        "height": Number(h, ..),
        "layers": Array(items),
        ..
      } => {
        let layers = items.map(item => {
          match item {
            {
              "name": String(name),
              "data": String(data),
              "x": Number(x, ..),
              "y": Number(y, ..),
              ..
            } =>
              @ora.Node::Layer(
                @ora.Properties::new(name, x=integer(x), y=integer(y)),
                @ora.decode_png(@base64.decode(data)),
              )
            _ => raise @ora.InvalidDocument("Invalid sample layer")
          }
        })
        if layers.length() < 2 {
          raise @ora.InvalidDocument("Sample requires at least two layers")
        }
        let original = layers[layers.length() - 1]
        let d = @ora.Document::new(
          integer(w),
          integer(h),
          [
            @ora.Node::Group(
              @ora.Properties::new("中文信息（再编排）"),
              Isolate,
              layers[:layers.length() - 1].to_owned(),
            ),
            original,
          ],
          name="星际漫游 · 海报再编排",
        )
        let response = snapshot(d)
        current.val = Some(d)
        original_source.val = None
        response.stringify()
      }
      { "action": "sample", .. } => {
        let d = sample()
        current.val = Some(d)
        original_source.val = None
        snapshot(d).stringify()
      }
      { "action": "open", "data": String(s), .. } => {
        let bytes = @base64.decode(s)
        let inspected = @ora.inspect(bytes)
        let response = try {
          let d = @ora.read(bytes)
          let result = snapshot(d)
          current.val = Some(d)
          let fields = match result {
            Object(fields) => fields
            _ => abort("Expected object")
          }
          match inspected {
            { "png": preview, .. } => fields["original"] = preview
            _ => ()
          }
          fields["editable"] = true
          result
        } catch {
          e => {
            let fields = match inspected {
              Object(fields) => fields
              _ => abort("Expected object")
            }
            fields["ok"] = true
            fields["editable"] = false
            fields["warning"] = match e {
              @ora.Unsupported(s) => Json::string(s)
              _ => Json::string(e.to_string())
            }
            current.val = None
            inspected
          }
        }
        original_source.val = Some(bytes)
        response.stringify()
      }
      { "action": "export", .. } => {
        let bytes = match current.val {
          Some(d) => d.write()
          None =>
            match original_source.val {
              Some(b) => b
              None => raise @ora.InvalidDocument("Open a document first")
            }
        }
        let response : Json = { "ok": true, "data": @base64.encode(bytes[:]) }
        response.stringify()
      }
      _ => {
        let doc = match current.val {
          Some(d) => d
          None => raise @ora.InvalidDocument("Open a document first")
        }
        match query {
          { "action": "remove", "path": Array(values), .. } => {
            let path = values.map(v => {
              match v {
                Number(n, ..) => integer(n)
                _ => raise @ora.InvalidDocument("Invalid path")
              }
            })
            let d = doc.remove(path)
            let result = snapshot(d)
            current.val = Some(d)
            result.stringify()
          }
          {
            "action": "reorder",
            "path": Array(values),
            "index": Number(index, ..),
            ..
          } => {
            let path = values.map(v => {
              match v {
                Number(n, ..) => integer(n)
                _ => raise @ora.InvalidDocument("Invalid path")
              }
            })
            let d = doc.reorder(path, integer(index))
            let result = snapshot(d)
            current.val = Some(d)
            result.stringify()
          }
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
                Number(n, ..) => integer(n)
                _ => raise @ora.InvalidDocument("Invalid path")
              }
            })
            let d = doc.set_properties(
              indices,
              @ora.Properties::new(
                name,
                x=integer(x),
                y=integer(y),
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
