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

///|
test "insertion deletion and reorder change render order without altering source" {
  let red = Layer(Properties::new("red"), Image::new(1, 1, [255, 0, 0, 255]))
  let blue = Layer(Properties::new("blue"), Image::new(1, 1, [0, 0, 255, 255]))
  let doc = Document::new(1, 1, [red])
  let added = doc.insert([], 0, blue)
  assert_eq(added.render().pixels(), [0, 0, 255, 255])
  assert_eq(added.reorder([0], 1).render().pixels(), [255, 0, 0, 255])
  assert_eq(added.remove([0]).render().pixels(), [255, 0, 0, 255])
  assert_eq(doc.children().length(), 1)
}
