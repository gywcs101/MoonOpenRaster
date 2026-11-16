///|
pub fn Image::encode_png(self : Image) -> Bytes raise {
  @png.encode(
    @raster.Image::of(
      self.width,
      self.height,
      Rgba8,
      Bytes::from_array(self.pixels),
    ),
    options={ ..@png.EncodeOptions::default(), palette: false, },
  )
}

///|
pub fn decode_png(data : Bytes) -> Image raise {
  if data.length() < 29 {
    raise InvalidDocument("Truncated PNG")
  }
  if data[24] != 8 {
    raise Unsupported("Only 8-bit PNG input is currently supported")
  }
  let image = @png.decode(data[:])
  if image.metadata.icc is Some(_) {
    raise Unsupported("ICC-profiled PNG requires color management")
  }
  let rgba = image.convert(Rgba8).to_straight()
  Image::new(rgba.width, rgba.height, rgba.pixels.to_array())
}
