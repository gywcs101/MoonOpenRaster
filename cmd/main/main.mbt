///|
fn describe(nodes : Array[@ora.Node], prefix : String) -> Unit {
  for i, node in nodes {
    let path = prefix + i.to_string()
    match node {
      Layer(p, image) =>
        println(
          path +
          "  " +
          p.name +
          "  " +
          image.width().to_string() +
          "x" +
          image.height().to_string(),
        )
      Group(p, _, children) => {
        println(path + "  [" + p.name + "]")
        describe(children, path + "/")
      }
    }
  }
}

///|
fn run() -> Unit raise {
  let raw = @env.args()
  let offset = if raw.length() > 2 &&
    ["inspect", "render", "edit"].contains(raw[2]) {
    1
  } else {
    0
  }
  let args = raw[offset:].to_array()
  if args.length() < 3 {
    raise @ora.InvalidDocument(
      "Usage: ora inspect INPUT | render INPUT OUTPUT | edit INPUT OUTPUT EDITS.json",
    )
  }
  let doc = @ora.read(@fs.read_file_to_bytes(args[2]))
  if args[1] == "inspect" {
    println(
      doc.name() +
      "  " +
      doc.width().to_string() +
      "x" +
      doc.height().to_string(),
    )
    describe(doc.children(), "")
    return
  }
  if args.length() < 4 {
    raise @ora.InvalidDocument("Missing output path")
  }
  if @fs.path_exists(args[3]) {
    raise @ora.InvalidDocument("Output exists: " + args[3])
  }
  let output = match args[1] {
    "render" => doc.render().encode_png()
    "edit" => {
      if args.length() != 5 {
        raise @ora.InvalidDocument("edit requires an edits JSON array")
      }
      let edits = @json.parse(@fs.read_file_to_string(args[4]))
      let mut current = doc
      match edits {
        Array(items) =>
          for item in items {
            let path = match item {
              { "path": Array(values), .. } =>
                values.map(fn(v) raise {
                  match v {
                    Number(n, ..) => n.to_int()
                    _ => raise @ora.InvalidDocument("Path must contain numbers")
                  }
                })
              _ => raise @ora.InvalidDocument("Missing path")
            }
            let name = match item {
              { "name": String(n), .. } => n
              _ => "Layer"
            }
            let x = match item {
              { "x": Number(n, ..), .. } => n.to_int()
              _ => 0
            }
            let y = match item {
              { "y": Number(n, ..), .. } => n.to_int()
              _ => 0
            }
            let opacity = match item {
              { "opacity": Number(n, ..), .. } => n
              _ => 1.0
            }
            let visible = match item {
              { "visible": False, .. } => false
              _ => true
            }
            let op = match item {
              { "composite_op": String(s), .. } => s
              _ => "svg:src-over"
            }
            current = current.set_properties(
              path,
              @ora.Properties::new(
                name,
                x~,
                y~,
                opacity~,
                visible~,
                composite_op=op,
              ),
            )
          }
        _ => raise @ora.InvalidDocument("Edits must be an array")
      }
      current.write()
    }
    _ => raise @ora.InvalidDocument("Unknown command: " + args[1])
  }
  @fs.write_bytes_to_file(args[3], output)
}

///|
fn main {
  run() catch {
    e => {
      eprintln(
        match e {
          @ora.InvalidDocument(s) => "Invalid document: " + s
          @ora.Unsupported(s) => "Unsupported feature: " + s
          _ => e.to_string()
        },
      )
      @env.exit(1)
    }
  }
}
