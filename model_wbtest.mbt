///|
test "image owns input and output buffers" {
  let pixels : Array[Byte] = [255, 0, 0, 255]
  let image = Image::new(1, 1, pixels)
  pixels[0] = 0
  let result = image.pixels()
  assert_eq(result[0], 255)
  result[0] = 0
  assert_eq(image.pixels()[0], 255)
}

///|
test "cyclic externally built groups fail before cloning" {
  let children : Array[Node] = []
  children.push(Group(Properties::new("cycle"), Isolate, children))
  let result = Ok(Document::new(1, 1, children)) catch { e => Err(e) }
  assert_true(result is Err(_))
  let doc = Document::new(1, 1, [])
  let replacement = Ok(doc.replace_children(children)) catch { e => Err(e) }
  assert_true(replacement is Err(_))
  let insertion = Ok(doc.insert([], 0, children[0])) catch { e => Err(e) }
  assert_true(insertion is Err(_))
}
