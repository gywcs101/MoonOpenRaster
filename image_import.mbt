///|
/// Decode a standalone raster or supported SVG image for insertion as a layer.
/// GIF and TIFF import their first frame or page.
pub fn decode_image(data : Bytes) -> Image raise {
  if data.length() > 33554432 {
    raise InvalidDocument("Image import exceeds 32 MiB")
  }
  let bytes = data[:]
  if bytes.has_prefix(b"\x89PNG\r\n\x1a\n"[:]) {
    return decode_png(data)
  }
  if looks_like_svg_xml(bytes) {
    return decode_svg(data)
  }
  let image = if bytes.has_prefix(b"\xff\xd8"[:]) {
    check_jpeg_import(bytes)
    @jpeg.decode(bytes, limits=image_limits, orient=true)
  } else if data.length() >= 12 &&
    bytes[:4].equal_to_bytes(b"RIFF") &&
    bytes[8:12].equal_to_bytes(b"WEBP") {
    check_static_webp(bytes)
    @webp.decode(bytes, limits=image_limits)
  } else if bytes.has_prefix(b"GIF87a"[:]) || bytes.has_prefix(b"GIF89a"[:]) {
    first_gif_frame(bytes)
  } else if bytes.has_prefix(b"BM"[:]) {
    check_bmp_profile(bytes)
    @bmp.decode(bytes, limits=image_limits)
  } else if bytes.has_prefix(b"II\x2a\x00"[:]) ||
    bytes.has_prefix(b"MM\x00\x2a"[:]) {
    let page = first_tiff_page(data)
    let image = @tiff.decode(page[:], limits=image_limits)
    image.upright(@tiff.orientation(page[:]))
  } else if bytes.has_prefix(b"\x00\x00\x01\x00"[:]) {
    // Limit the number of icon images the dependency can decode at once.
    if bytes.length() < 6 || read_image_uint(bytes, 4, 2, true) > 64L {
      raise InvalidDocument("ICO icon directory exceeds limits")
    }
    @ico.decode(bytes, limits={
      width: 256,
      height: 256,
      pixels: 65536,
      bytes: 524288,
    })
  } else {
    raise Unsupported(
      "Image format is unsupported (PNG, JPEG, WebP, GIF, BMP, TIFF, ICO, SVG)",
    )
  }
  normalize_raster(image)
}

///|
fn read_image_uint(
  data : BytesView,
  at : Int32,
  count : Int32,
  little : Bool,
) -> Int64 raise OraError {
  if at < 0 || at > data.length() - count {
    raise InvalidDocument("Truncated image metadata")
  }
  let mut value = 0L
  for i in 0..<count {
    let offset = if little { at + count - 1 - i } else { at + i }
    value = value * 256L + data[offset].to_int().to_int64()
  }
  value
}

///|
fn check_jpeg_import(bytes : BytesView) -> Unit raise OraError {
  // The JPEG decoder currently does not surface APP2 ICC metadata.
  let mut i = 2
  while i + 1 < bytes.length() && bytes[i] == 255 {
    let marker = bytes[i + 1].to_int()
    if marker == 255 {
      i += 1
      continue
    }
    if marker == 0xDA || marker == 0xD9 {
      break
    }
    let count = read_image_uint(bytes, i + 2, 2, false).to_int()
    if count < 2 || count > bytes.length() - i - 2 {
      raise InvalidDocument("Truncated JPEG segment")
    }
    if marker == 0xE2 &&
      count >= 14 &&
      bytes[i + 4:i + 16].equal_to_bytes(b"ICC_PROFILE\x00") {
      raise Unsupported("JPEG ICC color management is unsupported")
    }
    if marker == 0xC2 {
      check_progressive_jpeg(bytes[i + 4:i + 2 + count])
    }
    i += count + 2
  }
}

///|
fn check_progressive_jpeg(frame : BytesView) -> Unit raise OraError {
  if frame.length() < 6 {
    raise InvalidDocument("Truncated progressive JPEG frame")
  }
  let height = read_image_uint(frame, 1, 2, false).to_int()
  let width = read_image_uint(frame, 3, 2, false).to_int()
  let components = frame[5].to_int()
  if components == 0 || frame.length() < 6 + components * 3 {
    raise InvalidDocument("Invalid progressive JPEG component header")
  }
  let mut hmax = 1
  let mut vmax = 1
  for i in 0..<components {
    let factor = frame[7 + i * 3].to_int()
    hmax = hmax.max(factor >> 4)
    vmax = vmax.max(factor & 15)
  }
  let mcu_w = (width + 8 * hmax - 1) / (8 * hmax)
  let mcu_h = (height + 8 * vmax - 1) / (8 * vmax)
  for i in 0..<components {
    let factor = frame[7 + i * 3].to_int()
    let h = factor >> 4
    let v = factor & 15
    // moonimage 0.2.0 uses the padded component grid even for progressive
    // scans that omit padding, shifting coefficients into the wrong blocks.
    if (width * h + 8 * hmax - 1) / (8 * hmax) != mcu_w * h ||
      (height * v + 8 * vmax - 1) / (8 * vmax) != mcu_h * v {
      raise Unsupported(
        "Progressive JPEG edge sampling is unsupported; export as baseline JPEG or PNG",
      )
    }
  }
}

///|
fn check_static_webp(bytes : BytesView) -> Unit raise OraError {
  // Decode at most one still image; the dependency's general decoder collects all frames.
  let mut at = 12
  let mut pictures = 0
  while at + 8 <= bytes.length() {
    let tag = bytes[at:at + 4]
    let size = read_image_uint(bytes, at + 4, 4, true)
    if size > (bytes.length() - at - 8).to_int64() {
      raise InvalidDocument("Truncated WebP chunk")
    }
    if tag.equal_to_bytes(b"ANIM") || tag.equal_to_bytes(b"ANMF") {
      raise Unsupported("Animated WebP is unsupported; import a still frame")
    }
    if tag.equal_to_bytes(b"ICCP") {
      raise Unsupported("WebP ICC color management is unsupported")
    }
    if tag.equal_to_bytes(b"VP8 ") || tag.equal_to_bytes(b"VP8L") {
      pictures += 1
      if pictures > 1 {
        raise InvalidDocument("Multiple picture chunks in still WebP")
      }
    }
    at += 8 + size.to_int() + size.to_int() % 2
  }
}

///|
fn check_bmp_profile(bytes : BytesView) -> Unit raise OraError {
  let header_size = read_image_uint(bytes, 14, 4, true)
  if header_size >= 108L {
    let color_space = read_image_uint(bytes, 70, 4, true)
    if color_space != 0x73524742L && color_space != 0x57696e20L {
      raise Unsupported("BMP color space requires color management")
    }
  }
}

///|
fn first_tiff_page(data : Bytes) -> Bytes raise OraError {
  let bytes = data[:]
  let little = data[0] == 0x49
  let first = read_image_uint(bytes, 4, 4, little)
  if first < 8L || first > (data.length() - 2).to_int64() {
    raise InvalidDocument("Invalid TIFF first directory")
  }
  let count = read_image_uint(bytes, first.to_int(), 2, little)
  let next = first + 2L + count * 12L
  if next > (data.length() - 4).to_int64() {
    raise InvalidDocument("Truncated TIFF directory")
  }
  if read_image_uint(bytes, next.to_int(), 4, little) == 0L {
    return data
  }
  // The directory can point to pixel data elsewhere in the file. Keep all bytes
  // and sever only the next-page link in a private copy.
  let copy = data.to_array()
  for i in 0..<4 {
    copy[next.to_int() + i] = 0
  }
  Bytes::from_array(copy)
}

///|
fn gif_block_end(data : BytesView, start : Int32) -> Int32 raise OraError {
  let mut at = start
  while at < data.length() {
    let size = data[at].to_int()
    at += 1
    if size == 0 {
      return at
    }
    at += size
  }
  raise InvalidDocument("Truncated GIF data block")
}

///|
fn first_gif_frame(data : BytesView) -> @raster.Image raise {
  if data.length() < 13 {
    raise InvalidDocument("Truncated GIF header")
  }
  let packed = data[10].to_int()
  let mut at = 13 +
    (if (packed & 128) != 0 { 3 * (2 << (packed & 7)) } else { 0 })
  while at < data.length() {
    match data[at].to_int() {
      0x21 => {
        if at + 2 > data.length() {
          break
        }
        // ICCRGBG1012 is the application extension identifying GIF ICC data.
        if at + 14 <= data.length() &&
          data[at + 1] == 0xff &&
          data[at + 2] == 11 &&
          data[at + 3:at + 14].equal_to_bytes(b"ICCRGBG1012") {
          raise Unsupported("GIF ICC color management is unsupported")
        }
        at = gif_block_end(data, at + 2)
      }
      0x2c => {
        if at + 10 > data.length() {
          break
        }
        let flags = data[at + 9].to_int()
        let palette = if (flags & 128) != 0 {
          3 * (2 << (flags & 7))
        } else {
          0
        }
        let end = gif_block_end(data, at + 11 + palette)
        // End after the first complete image block so later frames can't consume memory.
        let animation = @gif.decode_animation(data[:end], limits=image_limits)
        let frame = animation.frames[0]
        let image = frame.image
        if frame.x == 0 &&
          frame.y == 0 &&
          image.width == animation.width &&
          image.height == animation.height {
          return image
        }
        let canvas = @raster.Image::new(
          animation.width,
          animation.height,
          Rgba8,
        )
        return canvas.composite(image, x=frame.x, y=frame.y)
      }
      _ => break
    }
  }
  raise InvalidDocument("GIF contains no complete first frame")
}
