///|
pub fn Image::encode_png(self : Image) -> Bytes raise {
  let format = if self.bits == 16 {
    @raster.PixelFormat::Rgba16
  } else {
    @raster.PixelFormat::Rgba8
  }
  @png.encode(
    @raster.Image::of(
      self.width,
      self.height,
      format,
      Bytes::from_array(self.pixels),
      metadata={
        ..@raster.Metadata::default(),
        intent: if self.bits == 16 {
          Some(Perceptual)
        } else {
          None
        },
      },
    ),
    options={
      ..@png.EncodeOptions::default(),
      palette: false,
      interlace: false,
    },
  )
}

///|
fn color_transform(
  image : @raster.Image,
) -> ((Double, Double, Double) -> (Double, Double, Double))? raise OraError {
  let metadata = image.metadata
  if metadata.icc is Some(profile) {
    // SHA-256 of Krita 5.3.4's bundled sRGB-elle-V2-srgbtrc.icc.
    if @sha2.hash(profile.profile[:], kind=Sha256) ==
      b"\x59\x91\xc8\xd8\xfc\xb6\x28\xda\xd5\xd0\x52\xd9\x34\x1d\xf8\xa3\x2b\xd3\xc7\xa7\x94\xc9\x13\xa8\xed\xe8\xea\xe4\xb3\x4b\x45\x45" {
      return None
    }
    let gray = match image.format {
      Gray8 | GrayAlpha8 | Gray16 | GrayAlpha16 => true
      _ => false
    }
    return Some(icc_rgb_transform(profile.profile[:], gray))
  }
  if metadata.intent is Some(_) {
    return None
  }
  let gamma = metadata.gamma.unwrap_or(0.45455)
  guard gamma > 0.0 else { raise InvalidDocument("Invalid PNG gamma") }
  let chroma = metadata.chromaticities.unwrap_or(@raster.Chromaticities::srgb())
  let canonical_gamma = (gamma - 0.45455).abs() <= 0.000005
  if chroma != @raster.Chromaticities::srgb() {
    let linearize : (Double) -> Double = if metadata.gamma is None {
      decode_srgb
    } else {
      value => @math.pow(value, 1.0 / gamma)
    }
    return Some(png_color_space(chroma, linearize))
  }
  if !canonical_gamma {
    let exponent = 1.0 / gamma
    return Some(fn(r, g, b) {
      (
        encode_srgb(@math.pow(r, exponent)),
        encode_srgb(@math.pow(g, exponent)),
        encode_srgb(@math.pow(b, exponent)),
      )
    })
  }
  None
}

///|
pub fn decode_png(data : Bytes) -> Image raise {
  let cicp = check_static_png(data)
  normalize_raster(decode_raster(data), original=Some(data), cicp~)
}

///|
fn normalize_raster(
  image : @raster.Image,
  original~ : Bytes? = None,
  cicp~ : (Int32, Int32)? = None,
) -> Image raise OraError {
  let transform = match cicp {
    Some((primaries, transfer)) => png_cicp_color(primaries, transfer)
    None => color_transform(image)
  }
  let bits = image.format.bits()
  let format = if bits == 16 {
    @raster.PixelFormat::Rgba16
  } else {
    @raster.PixelFormat::Rgba8
  }
  let rgba = image.to_straight().convert(format)
  let result : Image = {
    width: rgba.width,
    height: rgba.height,
    pixels: rgba.pixels.to_array(),
    bits,
    vector_source: None,
    vector_path: None,
    raster_source: if transform is Some(_) {
      original
    } else {
      None
    },
  }
  if transform is Some(convert) {
    let maximum = if bits == 16 { 65535.0 } else { 255.0 }
    for pixel in 0..<(result.width * result.height) {
      let i = pixel * 4
      let (r, g, b) = convert(
        result.sample(i).to_double() / maximum,
        result.sample(i + 1).to_double() / maximum,
        result.sample(i + 2).to_double() / maximum,
      )
      guard r >= 0.0 && r <= 1.0 && g >= 0.0 && g <= 1.0 && b >= 0.0 && b <= 1.0 else {
        raise InvalidDocument("PNG color transform produced an invalid sample")
      }
      result.put_sample(i, (r * maximum + 0.5).to_int())
      result.put_sample(i + 1, (g * maximum + 0.5).to_int())
      result.put_sample(i + 2, (b * maximum + 0.5).to_int())
    }
  }
  result
}

///|
fn decode_raster(data : Bytes) -> @raster.Image raise {
  @png.decode(data[:], limits=image_limits)
}

///|
/// Reject features that a still-image decode would otherwise silently discard.
fn check_static_png(data : Bytes) -> (Int32, Int32)? raise OraError {
  if data.length() < 8 || data[:8].to_owned() != b"\x89PNG\r\n\x1a\n" {
    raise InvalidDocument("Expected a PNG layer resource")
  }
  let mut at = 8
  let mut cicp = None
  while at + 12 <= data.length() {
    let mut size = 0L
    for i in 0..<4 {
      size = size * 256L + data[at + i].to_int().to_int64()
    }
    if size > (data.length() - at - 12).to_int64() {
      raise InvalidDocument("Truncated PNG chunk")
    }
    let tag = data[at + 4:at + 8].to_owned()
    if tag == b"acTL" {
      raise Unsupported("Animated PNG layer is unsupported")
    }
    if tag == b"cICP" {
      guard size == 4L && cicp is None else {
        raise InvalidDocument("Invalid or duplicate PNG cICP chunk")
      }
      guard data[at + 10] == 0 && data[at + 11] == 1 else {
        raise Unsupported(
          "PNG cICP requires full-range RGB for this conversion",
        )
      }
      cicp = Some((data[at + 8].to_int(), data[at + 9].to_int()))
    }
    at += size.to_int() + 12
    if tag == b"IEND" {
      break
    }
  }
  cicp
}

///|
let image_limits : @raster.Limits = {
  width: 16384,
  height: 16384,
  pixels: 16777216,
  bytes: 134217728,
}
