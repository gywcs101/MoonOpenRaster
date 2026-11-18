///|
fn first_layer(
  nodes : Array[@ora.Node],
  prefix : Array[Int32],
) -> Array[Int32]? {
  for i, node in nodes {
    let path = prefix.copy()
    path.push(i)
    match node {
      Layer(_, _) => return Some(path)
      Group(_, _, children) =>
        if first_layer(children, path) is Some(found) {
          return Some(found)
        }
    }
  }
  None
}

///|
fn main raise {
  let args = @env.args()
  // moon run on JS includes the node executable and generated script.
  let offset = if args.length() > 1 && args[1].has_suffix(".js") {
    2
  } else {
    1
  }
  let source = if args.length() > offset {
    @ora.read(@fs.read_file_to_bytes(args[offset]))
  } else {
    @ora.Document::new(
      4,
      4,
      [
        Group(@ora.Properties::new("海报内容"), Isolate, [
          Layer(
            @ora.Properties::new("标题", x=1, y=1),
            @ora.Image::new(
              2,
              2,
              Array::makei(16, i => if i % 4 == 3 { 255 } else { 220 }),
            ),
          ),
        ]),
        Layer(
          @ora.Properties::new("背景"),
          @ora.Image::new(
            4,
            4,
            Array::makei(64, i => if i % 4 == 3 { 255 } else { 24 }),
          ),
        ),
      ],
      name="消费者往返示例",
    )
  }
  let path = first_layer(source.children(), []).unwrap()
  let properties = match source.node(path) {
    Layer(p, _) => p
    _ => abort("Expected layer")
  }
  let raw_layer = @ora.decode_png(source.layer_png(path))
  let replacement = @ora.Image::new(
    raw_layer.width(),
    raw_layer.height(),
    Array::makei(raw_layer.width() * raw_layer.height() * 4, i => {
      if i % 4 == 3 {
        255
      } else {
        128
      }
    }),
  )
  let edited = source
    .set_properties(
      path,
      @ora.Properties::new(
        properties.name + "（已编辑）",
        x=-1,
        y=2,
        opacity=0.75,
        visible=true,
        composite_op="svg:src-over",
      ),
    )
    .replace_image(path, replacement)
  let duplicated = edited.duplicate(path, name="复制的图层")
  let result = duplicated.move_to(
    path,
    [],
    duplicated.remove(path).children().length(),
  )
  let archive = result.write()
  let reopened = @ora.read(archive)
  assert_eq(reopened.render().pixels(), result.render().pixels())
  assert_eq(source.layer_png(path), raw_layer.encode_png())
  assert_true(result.layers_zip().length() > 0)
  // Accessors are detached: callers cannot modify the document or history.
  let detached = source.children()
  detached.clear()
  assert_true(!source.children().is_empty())
  let pixels = replacement.pixels()
  pixels.clear()
  assert_eq(
    replacement.pixels().length(),
    raw_layer.width() * raw_layer.height() * 4,
  )
  if args.length() > offset + 1 {
    let output = args[offset + 1]
    if @fs.path_exists(output) {
      raise @ora.InvalidDocument("Output exists: " + output)
    }
    @fs.write_bytes_to_file(output, archive)
  }
  println(
    "consumer PASS: nested edit, pixel replacement, duplicate, move, render, save and reopen",
  )
}
