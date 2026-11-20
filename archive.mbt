///|
fn archive_u16(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() + (data[offset + 1].to_int() << 8)
}

///|
fn archive_u32(data : Bytes, offset : Int32) -> Int64 {
  archive_u16(data, offset).to_int64() +
  (archive_u16(data, offset + 2).to_int64() << 16)
}

///|
fn archive_zip64_count(data : Bytes) -> Int32? raise OraError {
  let mut footer = data.length() - 22
  let lower = (footer - 65535).max(0)
  while footer >= lower {
    if data[footer:footer + 4] == b"PK\x05\x06"[:] &&
      footer + 22 + archive_u16(data, footer + 20) == data.length() {
      let locator = footer - 20
      if locator < 0 || data[locator:locator + 4] != b"PK\x06\x07"[:] {
        return None
      }
      let offset = archive_u32(data, locator + 8)
      guard archive_u32(data, locator + 12) == 0L &&
        offset + 56L <= locator.to_int64() else {
        raise InvalidDocument("Invalid ZIP64 directory offset")
      }
      let offset = offset.to_int()
      guard data[offset:offset + 4] == b"PK\x06\x06"[:] else {
        raise InvalidDocument("Missing ZIP64 directory record")
      }
      let record_size = archive_u32(data, offset + 4)
      let directory_size = archive_u32(data, offset + 40)
      let directory_offset = archive_u32(data, offset + 48)
      guard archive_u32(data, offset + 8) == 0L &&
        archive_u32(data, offset + 44) == 0L &&
        archive_u32(data, offset + 52) == 0L &&
        record_size >= 44L &&
        offset.to_int64() + record_size + 12L == locator.to_int64() &&
        directory_offset + directory_size <= offset.to_int64() else {
        raise InvalidDocument("Invalid ZIP64 directory bounds")
      }
      let count = archive_u32(data, offset + 32)
      guard archive_u32(data, offset + 36) == 0L && count <= 4096L else {
        raise InvalidDocument("Too many archive entries")
      }
      return Some(count.to_int())
    }
    footer -= 1
  }
  None
}

///|
pub fn archive_entries(data : Bytes) -> Array[(String, Bytes)] raise {
  if data.length() > 268435456 {
    raise InvalidDocument("Archive exceeds 256 MiB input limit")
  }
  // ZIP64 extra fields can omit ordinary sizes when only the offset is wide.
  // moonzip 0.4.0's central-directory reader assumes fixed offsets for those
  // fields. On ZIP64 input use its bounded local-member reader and check the
  // count using the ZIP64 directory record.
  let count = match archive_zip64_count(data) {
    Some(count) => count
    None => @zip.names(data[:]).length()
  }
  if count > 4096 {
    raise InvalidDocument("Too many archive entries")
  }
  let seen : Map[String, Bool] = Map([])
  let reader = @zip.Reader::new(data[:])
  let result : Array[(String, Bytes)] = []
  let mut total = 0L
  while true {
    let e = match reader.next(limit=67108864) {
      Some(e) => e
      None => break
    }
    if result.length() >= count {
      raise InvalidDocument("Archive contains more members than its directory")
    }
    let name = e.name
    if seen.contains(name) {
      raise InvalidDocument("Duplicate resource: " + name)
    }
    if name.has_prefix("/") ||
      name.split("/").any(part => part == "..") ||
      name.contains("\\") {
      raise InvalidDocument("Unsafe archive path: " + name)
    }
    seen[name] = true
    total = total + e.data.length().to_int64()
    if total > 268435456L {
      raise InvalidDocument("Expanded archive exceeds limit")
    }
    result.push((e.name, e.data))
  }
  if result.length() != count {
    raise InvalidDocument("Archive member count does not match its directory")
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
