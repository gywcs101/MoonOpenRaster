///|
test "isolated group opacity differs from per-layer opacity" {
  let red = Image::new(1, 1, [255, 0, 0, 255])
  let blue = Image::new(1, 1, [0, 0, 255, 255])
  let group = Document::new(1, 1, [
    Group(Properties::new("group", opacity=0.5), Isolate, [
      Layer(Properties::new("red"), red),
      Layer(Properties::new("blue"), blue),
    ]),
  ])
  let separate = Document::new(1, 1, [
    Layer(Properties::new("red", opacity=0.5), red),
    Layer(Properties::new("blue", opacity=0.5), blue),
  ])
  assert_eq(group.render().pixels(), [255, 0, 0, 128])
  assert_eq(separate.render().pixels()[3], 192)
}

///|
test "negative coordinates clip pixel placement" {
  let image = Image::new(2, 1, [255, 0, 0, 255, 0, 255, 0, 255])
  let doc = Document::new(1, 1, [Layer(Properties::new("offset", x=-1), image)])
  assert_eq(doc.render().pixels(), [0, 255, 0, 255])
}

///|
test "pass through opacity multiplies child opacity and ignores obsolete group offsets" {
  let image = Image::new(1, 1, [255, 0, 0, 255])
  let doc = Document::new(1, 1, [
    Group(Properties::new("auto", x=100, y=100, opacity=0.5), Auto, [
      Layer(Properties::new("red", opacity=0.5), image),
    ]),
  ])
  assert_eq(doc.render().pixels(), [255, 0, 0, 64])
}
