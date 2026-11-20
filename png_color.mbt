///|
fn decode_srgb(value : Double) -> Double {
  if value <= 0.04045 {
    value / 12.92
  } else {
    @math.pow((value + 0.055) / 1.055, 2.4)
  }
}

///|
fn to_xyz(x : Double, y : Double) -> (Double, Double, Double) raise OraError {
  guard x >= 0.0 && y > 0.0 && x + y <= 1.000001 else {
    raise InvalidDocument("Invalid PNG color chromaticity")
  }
  (x / y, 1.0, (1.0 - x - y) / y)
}

///|
fn chroma_dot(
  a : (Double, Double, Double),
  b : (Double, Double, Double),
) -> Double {
  a.0 * b.0 + a.1 * b.1 + a.2 * b.2
}

///|
fn chroma_cross(
  a : (Double, Double, Double),
  b : (Double, Double, Double),
) -> (Double, Double, Double) {
  (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0)
}

///|
fn bradford(xyz : (Double, Double, Double)) -> (Double, Double, Double) {
  (
    chroma_dot((0.8951, 0.2664, -0.1614), xyz),
    chroma_dot((-0.7502, 1.7135, 0.0367), xyz),
    chroma_dot((0.0389, -0.0685, 1.0296), xyz),
  )
}

///|
fn png_color_space(
  chroma : @raster.Chromaticities,
  linearize : (Double) -> Double,
) -> ((Double, Double, Double) -> (Double, Double, Double)) raise OraError {
  let white = to_xyz(chroma.white_x, chroma.white_y)
  let r = to_xyz(chroma.red_x, chroma.red_y)
  let g = to_xyz(chroma.green_x, chroma.green_y)
  let b = to_xyz(chroma.blue_x, chroma.blue_y)
  let gc = chroma_cross(g, b)
  let bc = chroma_cross(b, r)
  let rc = chroma_cross(r, g)
  let determinant = chroma_dot(r, gc)
  guard determinant.abs() > 0.000001 else {
    raise InvalidDocument("Degenerate PNG RGB primary matrix")
  }
  let r_weight = chroma_dot(white, gc) / determinant
  let g_weight = chroma_dot(white, bc) / determinant
  let b_weight = chroma_dot(white, rc) / determinant
  let source_white = bradford(white)
  let d65 = bradford(to_xyz(0.3127, 0.3290))
  guard r_weight > 0.0 &&
    g_weight > 0.0 &&
    b_weight > 0.0 &&
    source_white.0 > 0.0 &&
    source_white.1 > 0.0 &&
    source_white.2 > 0.0 else {
    raise InvalidDocument("Invalid PNG color white point")
  }
  fn adapted(
    primary : (Double, Double, Double),
    weight : Double,
  ) -> (Double, Double, Double) {
    let lms = bradford(primary)
    let lms = (
      lms.0 * d65.0 / source_white.0,
      lms.1 * d65.1 / source_white.1,
      lms.2 * d65.2 / source_white.2,
    )
    let xyz = (
      chroma_dot((0.9869929, -0.1470543, 0.1599627), lms),
      chroma_dot((0.4323053, 0.5183603, 0.0492912), lms),
      chroma_dot((-0.0085287, 0.0400428, 0.9684867), lms),
    )
    (
      weight * chroma_dot((3.240969942, -1.537383178, -0.498610760), xyz),
      weight * chroma_dot((-0.969243636, 1.875967502, 0.041555057), xyz),
      weight * chroma_dot((0.055630080, -0.203976959, 1.056971514), xyz),
    )
  }
  let r = adapted(r, r_weight)
  let g = adapted(g, g_weight)
  let b = adapted(b, b_weight)
  fn(x, y, z) {
    let x = linearize(x)
    let y = linearize(y)
    let z = linearize(z)
    (
      encode_srgb(r.0 * x + g.0 * y + b.0 * z),
      encode_srgb(r.1 * x + g.1 * y + b.1 * z),
      encode_srgb(r.2 * x + g.2 * y + b.2 * z),
    )
  }
}

///|
fn png_cicp_color(
  primaries : Int32,
  transfer : Int32,
) -> ((Double, Double, Double) -> (Double, Double, Double))? raise OraError {
  if primaries == 1 && transfer == 13 {
    return None
  }
  let s = @raster.Chromaticities::srgb()
  let chroma = match primaries {
    1 => s
    9 =>
      {
        ..s,
        red_x: 0.708,
        red_y: 0.292,
        green_x: 0.170,
        green_y: 0.797,
        blue_x: 0.131,
        blue_y: 0.046,
      }
    12 => { ..s, red_x: 0.680, red_y: 0.320, green_x: 0.265, green_y: 0.690, }
    _ => raise Unsupported("Unsupported PNG cICP primaries")
  }
  let linearize : (Double) -> Double = match transfer {
    8 => value => value
    13 => decode_srgb
    _ => raise Unsupported("Unsupported PNG cICP transfer function")
  }
  Some(png_color_space(chroma, linearize))
}
