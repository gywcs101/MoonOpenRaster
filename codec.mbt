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
fn check_srgb(metadata : @raster.Metadata) -> Unit raise OraError {
  // SHA-256 of Krita 5.3.4's bundled sRGB-elle-V2-srgbtrc.icc.
  if metadata.icc is Some(profile) {
    if @sha2.hash(profile.profile[:], kind=Sha256) !=
      b"\x59\x91\xc8\xd8\xfc\xb6\x28\xda\xd5\xd0\x52\xd9\x34\x1d\xf8\xa3\x2b\xd3\xc7\xa7\x94\xc9\x13\xa8\xed\xe8\xea\xe4\xb3\x4b\x45\x45" {
      raise Unsupported("ICC-profiled image requires color management")
    }
  }
  if metadata.gamma is Some(gamma) {
    if (gamma - 0.45455).abs() > 0.000005 {
      raise Unsupported("Non-sRGB PNG gamma requires color management")
    }
  }
  if metadata.chromaticities is Some(chromaticities) {
    if chromaticities != @raster.Chromaticities::srgb() {
      raise Unsupported("Non-sRGB PNG chromaticities require color management")
    }
  }
}

///|
pub fn decode_png(data : Bytes) -> Image raise {
  check_static_png(data)
  normalize_raster(decode_raster(data))
}

///|
fn normalize_raster(image : @raster.Image) -> Image raise OraError {
  check_srgb(image.metadata)
  let bits = image.format.bits()
  let format = if bits == 16 {
    @raster.PixelFormat::Rgba16
  } else {
    @raster.PixelFormat::Rgba8
  }
  let rgba = image.to_straight().convert(format)
  {
    width: rgba.width,
    height: rgba.height,
    pixels: rgba.pixels.to_array(),
    bits,
  }
}

///|
fn decode_raster(data : Bytes) -> @raster.Image raise {
  @png.decode(data[:], limits=image_limits)
}

///|
/// Reject features that a still-image decode would otherwise silently discard.
fn check_static_png(data : Bytes) -> Unit raise OraError {
  if data.length() < 8 || data[:8].to_owned() != b"\x89PNG\r\n\x1a\n" {
    raise InvalidDocument("Expected a PNG layer resource")
  }
  let mut at = 8
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
      raise Unsupported("PNG cICP color description requires color management")
    }
    at += size.to_int() + 12
    if tag == b"IEND" {
      break
    }
  }
}

///|
let image_limits : @raster.Limits = {
  width: 16384,
  height: 16384,
  pixels: 16777216,
  bytes: 134217728,
}
