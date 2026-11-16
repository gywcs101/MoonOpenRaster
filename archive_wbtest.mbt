///|
test "archive accepts ordinary dotted names and rejects traversal components" {
  let valid = @zip.zip(
    [
      @zip.Entry::new("mimetype", b"image/openraster"),
      @zip.Entry::new("data/part..png", b"payload"),
    ][:],
  )
  assert_eq(archive_entries(valid).length(), 2)
  let invalid = @zip.zip(
    [
      @zip.Entry::new("mimetype", b"image/openraster"),
      @zip.Entry::new("data/../escape", b"payload"),
    ][:],
  )
  let result = Ok(archive_entries(invalid)) catch { e => Err(e) }
  assert_true(result is Err(_))
}

///|
test "duplicate archive resources are refused" {
  let data = @zip.zip(
    [
      @zip.Entry::new("mimetype", b"image/openraster"),
      @zip.Entry::new("same", b"a"),
      @zip.Entry::new("same", b"b"),
    ][:],
  )
  let result = Ok(archive_entries(data)) catch { e => Err(e) }
  assert_true(result is Err(_))
}
