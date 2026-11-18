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
fn run() -> Unit raise {
  let raw = @env.args()
  let offset = if raw.length() > 2 &&
    ["inspect", "render", "edit"].contains(raw[2]) {
    1
  } else {
    0
  }
  let args = raw[offset:].to_owned()
  if args.length() < 3 {
    raise @ora.InvalidDocument(
      "Usage: ora inspect INPUT | render INPUT OUTPUT | edit INPUT OUTPUT EDITS.json",
    )
  }
  let input = @fs.read_file_to_bytes(args[2])
  if args[1] == "inspect" {
    println(@ora.inspect(input).stringify())
    return
  }
  let doc = @ora.read(input)
  if args.length() < 4 {
    raise @ora.InvalidDocument("Missing output path")
  }
  if @fs.path_exists(args[3]) {
    raise @ora.InvalidDocument("Output exists: " + args[3])
  }
  for warning in doc.compatibility_warnings() {
    eprintln("Warning: " + warning)
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
                    Number(n, ..) => integer(n)
                    _ => raise @ora.InvalidDocument("Path must contain numbers")
                  }
                })
              _ => raise @ora.InvalidDocument("Missing path")
            }
            let previous = match current.node(path) {
              Layer(p, _) => p
              Group(p, _, _) => p
            }
            let name = match item {
              { "name": String(n), .. } => n
              { "name": _, .. } =>
                raise @ora.InvalidDocument("name must be a string")
              _ => previous.name
            }
            let x = match item {
              { "x": Number(n, ..), .. } => integer(n)
              { "x": _, .. } => raise @ora.InvalidDocument("x must be a number")
              _ => previous.x
            }
            let y = match item {
              { "y": Number(n, ..), .. } => integer(n)
              { "y": _, .. } => raise @ora.InvalidDocument("y must be a number")
              _ => previous.y
            }
            let opacity = match item {
              { "opacity": Number(n, ..), .. } => n
              { "opacity": _, .. } =>
                raise @ora.InvalidDocument("opacity must be a number")
              _ => previous.opacity
            }
            let visible = match item {
              { "visible": False, .. } => false
              { "visible": True, .. } => true
              { "visible": _, .. } =>
                raise @ora.InvalidDocument("visible must be a boolean")
              _ => previous.visible
            }
            let op = match item {
              { "composite_op": String(s), .. } => s
              { "composite_op": _, .. } =>
                raise @ora.InvalidDocument("composite_op must be a string")
              _ => previous.composite_op
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
      for warning in current.compatibility_warnings() {
        eprintln("Warning: " + warning)
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
