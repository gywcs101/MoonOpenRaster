///|
pub fn archive_entries(data : Bytes) -> Array[(String, Bytes)] raise {
  if data.length() > 268435456 {
    raise InvalidDocument("Archive exceeds 256 MiB input limit")
  }
  let names = @zip.names(data[:])
  if names.length() > 4096 {
    raise InvalidDocument("Too many archive entries")
  }
  let seen : Map[String, Bool] = Map([])
  for name in names {
    if seen.contains(name) {
      raise InvalidDocument("Duplicate resource: " + name)
    }
    if name.has_prefix("/") || name.contains("..") || name.contains("\\") {
      raise InvalidDocument("Unsafe archive path: " + name)
    }
    seen[name] = true
  }
  let entries = @zip.unzip(data[:], limit=67108864)
  let result : Array[(String, Bytes)] = []
  let mut total = 0L
  for e in entries {
    total = total + e.data.length().to_int64()
    if total > 268435456L {
      raise InvalidDocument("Expanded archive exceeds limit")
    }
    result.push((e.name, e.data))
  }
  if resource(result, "mimetype") != b"image/openraster" {
    raise InvalidDocument("Invalid mimetype")
  }
  result
}

///|
fn resource(
  entries : Array[(String, Bytes)],
  name : String,
) -> Bytes raise OraError {
  for (key, value) in entries {
    if key == name {
      return value
    }
  }
  raise InvalidDocument("Missing resource: " + name)
}
