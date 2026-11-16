///|
test "nested edits preserve source document" {
  let doc = Document::new(1, 1, [
    Group(Properties::new("group"), Isolate, [
      Layer(Properties::new("red"), Image::new(1, 1, [255, 0, 0, 255])),
    ]),
  ])
  let changed = doc.set_properties(
    [0, 0],
    Properties::new("hidden", visible=false),
  )
  assert_eq(changed.render().pixels(), [0, 0, 0, 0])
  assert_eq(doc.render().pixels(), [255, 0, 0, 255])
}
