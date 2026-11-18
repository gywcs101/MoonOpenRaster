///|
test "writer avoids preserved resource collisions and omits root rendering attributes" {
  let doc = Document::new(2, 2, [
    Group(Properties::new("group", x=99), Isolate, [
      Layer(
        Properties::new("layer", x=1, y=1),
        Image::new(1, 1, [4, 5, 6, 255]),
      ),
    ]),
  ])
  let doc = {
    ..doc,
    resources: [("data/moonopenraster-layer2.png", b"extension")],
    root_properties: Some({
      ..Properties::new("root", x=10, visible=false),
      extra: [("custom", "retained")],
    }),
  }
  let data = doc.write()
  let entries = archive_entries(data)
  assert_eq(resource(entries, "data/moonopenraster-layer2.png"), b"extension")
  let xml = @xml.loads(@utf8.decode(resource(entries, "stack.xml")))
  let root = xml.document_element().unwrap().child_elements()[0]
  assert_eq(root.attrs, [("custom", "retained")])
  let group = root.child_elements()[0]
  assert_eq(group.attr("x"), None)
  assert_eq(group.attr("y"), None)
  assert_eq(group.child_elements()[0].attr("x"), Some("1"))
  assert_eq(read(data).render().pixels(), doc.render().pixels())
}

///|
test "constructor getter extensions and edited history have independent ownership" {
  let input = [
    Layer(Properties::new("red"), Image::new(1, 1, [255, 0, 0, 255])),
  ]
  let doc = Document::new(1, 1, [Group(Properties::new("g"), Isolate, input)])
  input.clear()
  let attributes = [("alpha-preserve", "false")]
  let edited = doc.replace_extra([0, 0], attributes)
  attributes.clear()
  let detached = edited.children()
  match detached[0] {
    Group(_, _, c) => {
      match c[0] {
        Layer(p, _) => {
          let extra = p.extra()
          extra.clear()
        }
        _ => fail("layer")
      }
      c.clear()
    }
    _ => fail("group")
  }
  let changed = edited.set_properties(
    [0, 0],
    Properties::new("hidden", visible=false),
  )
  assert_eq(changed.render().pixels(), [0, 0, 0, 0])
  assert_eq(edited.render().pixels(), [255, 0, 0, 255])
  match edited.node([0, 0]) {
    Layer(p, _) => assert_eq(p.extra(), [("alpha-preserve", "false")])
    _ => fail("layer")
  }
  assert_true(
    (Ok(doc.replace_extra([0], [("opacity", "0")])) catch { e => Err(e) })
    is Err(_),
  )
  assert_true(
    (Ok(doc.replace_extra([0], [("custom", "1"), ("custom", "2")])) catch {
      e => Err(e)
    })
    is Err(_),
  )
}

///|
test "property editing shares immutable pixels and unaffected tree branches" {
  let doc = Document::new(1, 1, [
    Group(Properties::new("g"), Isolate, [
      Layer(Properties::new("a"), Image::new(1, 1, [1, 2, 3, 255])),
    ]),
    Group(Properties::new("untouched"), Auto, []),
  ])
  let edited = doc.set_properties([0, 0], Properties::new("renamed"))
  match (doc.children[0], edited.children[0]) {
    (Group(_, _, before), Group(_, _, after)) => {
      assert_false(physical_equal(before, after))
      match (before[0], after[0]) {
        (Layer(_, a), Layer(_, b)) =>
          assert_true(physical_equal(a.pixels, b.pixels))
        _ => fail("layers")
      }
    }
    _ => fail("groups")
  }
  assert_true(physical_equal(doc.children[1], edited.children[1]))
}

///|
test "move resolves original destination indices and duplicate preserves metadata" {
  let doc = Document::new(1, 1, [
    Layer(Properties::new("a"), Image::new(1, 1, [1, 2, 3, 255])),
    Group(Properties::new("g"), Auto, []),
  ]).replace_extra([0], [("custom", "yes")])
  let moved = doc.move_to([0], [1], 0)
  match moved.node([0, 0]) {
    Layer(p, _) => assert_eq(p.extra(), [("custom", "yes")])
    _ => fail("layer")
  }
  let dup = moved.duplicate([0], name="copy")
  match dup.node([0]) {
    Group(p, s, c) => {
      assert_eq(p.name, "copy")
      assert_true(s is Auto)
      assert_eq(c.length(), 1)
    }
    _ => fail("group")
  }
  assert_eq(doc.children().length(), 2)
  assert_true((Ok(moved.move_to([0], [0], 0)) catch { e => Err(e) }) is Err(_))
  assert_true(
    (Ok(moved.move_to([0], [0, 0], 0)) catch { e => Err(e) }) is Err(_),
  )
  assert_true((Ok(doc.move_to([0], [1], 1)) catch { e => Err(e) }) is Err(_))
  let same = Document::new(1, 1, [doc.node([0]), doc.node([0]), doc.node([0])])
  assert_eq(same.move_to([0], [], 2).children().length(), 3)
}

///|
test "layer exports retain intrinsic pixels and safe filenames with metadata" {
  let image = Image::new(1, 1, [11, 22, 33, 128])
  let doc = Document::new(1, 1, [
    Layer(Properties::new("../中文/unsafe", x=5, opacity=0.2), image),
  ])
  assert_eq(decode_png(doc.layer_png([0])).pixels(), image.pixels())
  let entries = @zip.unzip(doc.layers_zip())
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].name, "layer-0.png")
  assert_eq(decode_png(entries[0].data).pixels(), image.pixels())
  assert_true(@utf8.decode(entries[1].data).contains("../中文/unsafe"))
  assert_true((Ok(doc.layer_png([])) catch { e => Err(e) }) is Err(_))
}

///|
test "integer XML attributes reject coercions and overflow before conversion" {
  for
    value in [
      "1.5", "1e2", "2147483648", "999999999999999999999", "--1", "", "0x10",
    ] {
    let element = @dom.Element::new("layer", attrs=[("x", value)])
    assert_true((Ok(int_attr(element, "x", 0)) catch { e => Err(e) }) is Err(_))
  }
  assert_eq(
    int_attr(@dom.Element::new("layer", attrs=[("x", " +12 ")]), "x", 0),
    12,
  )
  assert_eq(
    int_attr(@dom.Element::new("layer", attrs=[("x", "-12")]), "x", 0),
    -12,
  )
  assert_true(
    (Ok(properties(@dom.Element::new("layer", attrs=[("visibility", "maybe")]))) catch {
      e => Err(e)
    })
    is Err(_),
  )
}

///|
test "plus warning survives serialization and uses W3C source plus destination" {
  let doc = Document::new(1, 1, [
    Layer(
      Properties::new("plus", composite_op="svg:plus"),
      Image::new(1, 1, [255, 0, 0, 128]),
    ),
  ])
  assert_eq(doc.compatibility_warnings().length(), 1)
  assert_eq(
    read(doc.write()).compatibility_warnings(),
    doc.compatibility_warnings(),
  )
  let resized = doc.render().resize_nearest(2, 2)
  assert_eq(resized.pixels().length(), 16)
  assert_true(
    (Ok(resized.resize_nearest(0, 1)) catch { e => Err(e) }) is Err(_),
  )
}
