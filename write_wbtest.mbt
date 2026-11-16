///|
test "document with nested group and escaped names round trips" {
  let image = Image::new(1, 1, [23, 45, 67, 255])
  let doc = Document::new(
    2,
    2,
    [
      Group(Properties::new("group & <test>"), Isolate, [
        Layer(Properties::new("layer", x=1, y=1), image),
      ]),
    ],
    name="sample",
  )
  let bytes = doc.write()
  let result = read(bytes)
  assert_eq(result.name(), "sample")
  assert_eq(result.render().pixels(), doc.render().pixels())
  assert_eq(bytes[8], 0)
}

///|
test "multicolor PNG export remains supported by reader" {
  let pixels = Array::makei(16 * 4, fn(i) { (i * 3).to_byte() })
  let image = Image::new(4, 4, pixels)
  assert_eq(decode_png(image.encode_png()).pixels(), pixels)
}
