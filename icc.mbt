///|
fn icc_uint(data : BytesView, at : Int32, width : Int32) -> Int64 {
  let mut value = 0L
  for i in at..<(at + width) {
    value = value * 256L + data[i].to_int().to_int64()
  }
  value
}

///|
fn icc_fixed(data : BytesView, at : Int32) -> Double {
  let value = icc_uint(data, at, 4)
  let signed = if value >= 2147483648L { value - 4294967296L } else { value }
  signed.to_double() / 65536.0
}

///|
fn icc_curve(data : BytesView) -> ((Double) -> Double) raise OraError {
  guard data.length() >= 12 else {
    raise InvalidDocument("Truncated ICC tone curve")
  }
  match data[:4].to_owned() {
    b"curv" => {
      let count = icc_uint(data, 8, 4)
      guard count <= ((data.length() - 12) / 2).to_int64() && count <= 65536L else {
        raise InvalidDocument("Invalid ICC tone curve sample count")
      }
      match count {
        0L => x => x
        1L => {
          let gamma = icc_uint(data, 12, 2).to_double() / 256.0
          guard gamma > 0.0 else { raise InvalidDocument("Invalid ICC gamma") }
          x => @math.pow(x, gamma)
        }
        _ => {
          let last = count.to_int() - 1
          fn(x) {
            let position = x * last.to_double()
            let i = position.to_int().min(last - 1)
            let low = icc_uint(data, 12 + 2 * i, 2).to_double()
            let high = icc_uint(data, 14 + 2 * i, 2).to_double()
            (low + (high - low) * (position - i.to_double())) / 65535.0
          }
        }
      }
    }
    b"para" => {
      let kind = icc_uint(data, 8, 2).to_int()
      let counts = [1, 3, 4, 5, 7]
      guard counts.get(kind) is Some(count) && 12 + count * 4 <= data.length() else {
        raise Unsupported("Unsupported ICC parametric curve")
      }
      let p = Array::makei(count, i => icc_fixed(data, 12 + 4 * i))
      guard p[0] > 0.0 && (kind == 0 || p[1] > 0.0) else {
        raise InvalidDocument("Invalid ICC parametric curve coefficients")
      }
      fn(x) {
        match kind {
          0 => @math.pow(x, p[0])
          1 =>
            if x >= -p[2] / p[1] {
              @math.pow((p[1] * x + p[2]).max(0.0), p[0])
            } else {
              0.0
            }
          2 =>
            if x >= -p[2] / p[1] {
              @math.pow((p[1] * x + p[2]).max(0.0), p[0]) + p[3]
            } else {
              p[3]
            }
          3 =>
            if x >= p[4] {
              @math.pow((p[1] * x + p[2]).max(0.0), p[0])
            } else {
              p[3] * x
            }
          _ =>
            if x >= p[4] {
              @math.pow((p[1] * x + p[2]).max(0.0), p[0]) + p[5]
            } else {
              p[3] * x + p[6]
            }
        }
      }
    }
    _ => raise Unsupported("Unsupported ICC tone curve type")
  }
}

///|
fn icc_xyz(data : BytesView) -> (Double, Double, Double) raise OraError {
  guard data.length() >= 20 && data[:4] == b"XYZ "[:] else {
    raise InvalidDocument("Invalid ICC XYZ colorant")
  }
  (icc_fixed(data, 8), icc_fixed(data, 12), icc_fixed(data, 16))
}

///|
fn encode_srgb(value : Double) -> Double {
  let value = value.max(0.0).min(1.0)
  if value <= 0.0031308 {
    12.92 * value
  } else {
    1.055 * @math.pow(value, 1.0 / 2.4) - 0.055
  }
}

///|
fn icc_xyz_srgb(x : Double, y : Double, z : Double) -> (Double, Double, Double) {
  // D50 XYZ to D65 linear sRGB, including Bradford adaptation.
  (
    encode_srgb(3.134135956 * x - 1.617386332 * y - 0.490661946 * z),
    encode_srgb(-0.978795502 * x + 1.916254568 * y + 0.033442731 * z),
    encode_srgb(0.071955379 * x - 0.228976826 * y + 1.405386058 * z),
  )
}

///|
fn icc_lab_srgb(
  lightness : Double,
  a : Double,
  b : Double,
) -> (Double, Double, Double) {
  let y = (lightness + 16.0) / 116.0
  fn inverse(t : Double) -> Double {
    if t > 6.0 / 29.0 {
      t * t * t
    } else {
      (116.0 * t - 16.0) / (24389.0 / 27.0)
    }
  }
  icc_xyz_srgb(
    0.9642 * inverse(y + a / 500.0),
    inverse(y),
    0.8249 * inverse(y - b / 200.0),
  )
}

///|
fn icc_interpolate_grid(
  input : Array[Double],
  grid : Array[Int32],
  sample : (Int32) -> Double,
  outputs~ : Int32 = 3,
) -> Array[Double] {
  let fractions : Array[(Double, Int32)] = []
  let mut cell = 0
  let mut stride = 1
  for channel = grid.length() - 1; channel >= 0; channel = channel - 1 {
    let position = input[channel].max(0.0).min(1.0) *
      (grid[channel] - 1).to_double()
    let lower = position.to_int().min(grid[channel] - 2)
    cell += lower * stride
    fractions.push((position - lower.to_double(), stride))
    stride *= grid[channel]
  }
  fractions.sort_by((a, b) => b.0.compare(a.0))
  Array::makei(outputs, channel => {
    let mut point = cell
    let mut previous = sample(point * outputs + channel)
    let mut value = previous
    for (fraction, step) in fractions {
      point += step
      let next = sample(point * outputs + channel)
      value += (next - previous) * fraction
      previous = next
    }
    value
  })
}

///|
fn icc_mab_transform(
  data : BytesView,
  gray : Bool,
  lab : Bool,
) -> ((Double, Double, Double) -> (Double, Double, Double)) raise OraError {
  let channels = if gray { 1 } else { 3 }
  guard data.length() >= 32 && data[8].to_int() == channels && data[9] == 3 else {
    raise Unsupported("Invalid ICC mAB header or channels")
  }
  fn offset(field : Int32) -> Int32 raise OraError {
    let value = icc_uint(data, field, 4)
    if value == 0L {
      return 0
    }
    guard value >= 32L && value < data.length().to_int64() && value % 4L == 0L else {
      raise InvalidDocument("Invalid ICC mAB stage offset")
    }
    value.to_int()
  }
  fn curves(
    first : Int32,
    count : Int32,
  ) -> Array[(Double) -> Double] raise OraError {
    let items : Array[(Double) -> Double] = []
    let mut at = first
    if at == 0 {
      return items
    }
    for _ in 0..<count {
      guard at + 12 <= data.length() else {
        raise InvalidDocument("Truncated ICC mAB curves")
      }
      let remaining = data[at:]
      let size = match remaining[:4].to_owned() {
        b"curv" => 12L + icc_uint(remaining, 8, 4) * 2L
        b"para" => {
          guard [1, 3, 4, 5, 7].get(icc_uint(remaining, 8, 2).to_int())
            is Some(n) else {
            raise Unsupported("Unsupported ICC mAB parametric curve")
          }
          (12 + n * 4).to_int64()
        }
        _ => raise Unsupported("Unsupported ICC mAB tone curve")
      }
      guard size <= remaining.length().to_int64() else {
        raise InvalidDocument("Truncated ICC mAB tone curve")
      }
      items.push(icc_curve(remaining[:size.to_int()]))
      at += (size.to_int() + 3) / 4 * 4
    }
    items
  }
  let b_offset = offset(12)
  let matrix_offset = offset(16)
  let middle_offset = offset(20)
  let lut_offset = offset(24)
  let a_offset = offset(28)
  guard b_offset != 0 &&
    (matrix_offset == 0) == (middle_offset == 0) &&
    (lut_offset == 0) == (a_offset == 0) &&
    (!gray || lut_offset != 0) else {
    raise InvalidDocument("Invalid ICC mAB stage combination")
  }
  let a = curves(a_offset, channels)
  let b = curves(b_offset, 3)
  let m = curves(middle_offset, 3)
  guard matrix_offset == 0 || matrix_offset + 48 <= data.length() else {
    raise InvalidDocument("Truncated ICC mAB matrix")
  }
  let matrix = if matrix_offset == 0 {
    []
  } else {
    Array::makei(12, i => icc_fixed(data, matrix_offset + 4 * i))
  }
  let grid : Array[Int32] = []
  let mut width = 0
  if lut_offset != 0 {
    guard lut_offset + 20 <= data.length() else {
      raise InvalidDocument("Truncated ICC mAB lookup table header")
    }
    width = data[lut_offset + 16].to_int()
    guard width == 1 || width == 2 else {
      raise Unsupported("Unsupported ICC mAB lookup sample width")
    }
    let mut entries = 1
    for i in 0..<channels {
      let points = data[lut_offset + i].to_int()
      guard points >= 2 && points <= 64 else {
        raise Unsupported("Unsupported ICC mAB grid size")
      }
      grid.push(points)
      entries *= points
    }
    guard lut_offset + 20 + entries * 3 * width <= data.length() else {
      raise InvalidDocument("Truncated ICC mAB lookup values")
    }
  }
  let sample_width = width
  fn(r, g, blue) {
    let input = [r, g, blue]
    let converted = if lut_offset == 0 {
      input
    } else {
      let warped = Array::makei(channels, i => a[i](input[i]))
      let maximum = if sample_width == 1 { 255.0 } else { 65535.0 }
      icc_interpolate_grid(warped, grid, i => {
        icc_uint(data, lut_offset + 20 + i * sample_width, sample_width).to_double() /
        maximum
      })
    }
    let result = if matrix.is_empty() {
      converted
    } else {
      let linear = Array::makei(3, i => m[i](converted[i].max(0.0).min(1.0)))
      Array::makei(3, i => {
        matrix[i * 3] * linear[0] +
        matrix[i * 3 + 1] * linear[1] +
        matrix[i * 3 + 2] * linear[2] +
        matrix[i + 9]
      })
    }
    let x = b[0](result[0].max(0.0).min(1.0)).max(0.0).min(1.0)
    let y = b[1](result[1].max(0.0).min(1.0)).max(0.0).min(1.0)
    let z = b[2](result[2].max(0.0).min(1.0)).max(0.0).min(1.0)
    if lab {
      icc_lab_srgb(x * 100.0, y * 255.0 - 128.0, z * 255.0 - 128.0)
    } else {
      let code = 65535.0 / 32768.0
      icc_xyz_srgb(x * code, y * code, z * code)
    }
  }
}

///|
fn icc_lut_transform(
  data : BytesView,
  gray : Bool,
  lab : Bool,
) -> ((Double, Double, Double) -> (Double, Double, Double)) raise OraError {
  guard data.length() >= 48 else {
    raise InvalidDocument("Truncated ICC lookup table")
  }
  let width = match data[:4].to_owned() {
    b"mft1" if lab => 1
    b"mft2" => 2
    _ =>
      raise Unsupported("Unsupported ICC lookup-table type or connection space")
  }
  let channels = if gray { 1 } else { 3 }
  guard data[8].to_int() == channels && data[9] == 3 else {
    raise Unsupported("Unsupported ICC lookup-table channel count")
  }
  let grid = data[10].to_int()
  guard grid >= 2 && grid <= 64 else {
    raise Unsupported("Unsupported ICC lookup-table grid size")
  }
  for i in 0..<9 {
    let expected = if i % 4 == 0 { 65536L } else { 0L }
    if icc_uint(data, 12 + i * 4, 4) != expected {
      raise Unsupported("ICC device lookup-table matrix must be identity")
    }
  }
  let (start, input_count, output_count) = if width == 1 {
    (48, 256, 256)
  } else {
    guard data.length() >= 52 else {
      raise InvalidDocument("Truncated ICC lut16 header")
    }
    (52, icc_uint(data, 48, 2).to_int(), icc_uint(data, 50, 2).to_int())
  }
  guard input_count >= 2 && output_count >= 2 else {
    raise InvalidDocument("ICC lookup-table curve is too short")
  }
  let input_end = start + input_count * channels * width
  let cube = if gray { grid } else { grid * grid * grid }
  let output_start = input_end + cube * 3 * width
  guard output_start + output_count * 3 * width <= data.length() else {
    raise InvalidDocument("Truncated ICC lookup-table values")
  }
  let maximum = if width == 1 { 255.0 } else { 65535.0 }
  fn sample(offset : Int32, index : Int32) -> Double {
    icc_uint(data, offset + index * width, width).to_double() / maximum
  }
  fn lookup(offset : Int32, count : Int32, value : Double) -> Double {
    let position = value.max(0.0).min(1.0) * (count - 1).to_double()
    let i = position.to_int().min(count - 2)
    let a = sample(offset, i)
    a + (sample(offset, i + 1) - a) * (position - i.to_double())
  }
  let dimensions = Array::make(channels, grid)
  fn(r, g, b) {
    let values = [r, g, b]
    let input = Array::makei(channels, i => {
      lookup(start + i * input_count * width, input_count, values[i])
    })
    let result = icc_interpolate_grid(input, dimensions, i => {
      sample(input_end, i)
    })
    for channel in 0..<3 {
      result[channel] = lookup(
        output_start + channel * output_count * width,
        output_count,
        result[channel],
      )
    }
    if lab {
      if width == 1 {
        icc_lab_srgb(
          result[0] * 100.0,
          result[1] * 255.0 - 128.0,
          result[2] * 255.0 - 128.0,
        )
      } else {
        let code = 65535.0 / 256.0
        icc_lab_srgb(
          result[0] * code / 255.0 * 100.0,
          result[1] * code - 128.0,
          result[2] * code - 128.0,
        )
      }
    } else {
      let code = 65535.0 / 32768.0
      icc_xyz_srgb(result[0] * code, result[1] * code, result[2] * code)
    }
  }
}

///|
fn icc_rgb_transform(
  data : BytesView,
  gray : Bool,
) -> ((Double, Double, Double) -> (Double, Double, Double)) raise OraError {
  guard data.length() >= 132 &&
    data.length() <= 1048576 &&
    icc_uint(data, 0, 4) == data.length().to_int64() &&
    data[36:40] == b"acsp"[:] else {
    raise Unsupported("Invalid or oversized ICC-profiled image")
  }
  let lab = data[20:24] == b"Lab "[:]
  guard (lab || data[20:24] == b"XYZ "[:]) && (data[8] == 2 || data[8] == 4) else {
    raise Unsupported(
      "ICC profile must use a Lab or XYZ connection space and ICC v2 or v4",
    )
  }
  guard (gray && data[16:20] == b"GRAY"[:]) ||
    (!gray && data[16:20] == b"RGB "[:]) else {
    raise Unsupported("ICC profile color space does not match the raster")
  }
  let count = icc_uint(data, 128, 4)
  guard count <= 512L && 132L + count * 12L <= data.length().to_int64() else {
    raise InvalidDocument("Invalid ICC tag table")
  }
  let tags : Map[Bytes, BytesView] = Map([])
  let table_end = 132 + count.to_int() * 12
  for index in 0..<count.to_int() {
    let at = 132 + index * 12
    let tag = data[at:at + 4].to_owned()
    let offset = icc_uint(data, at + 4, 4)
    let size = icc_uint(data, at + 8, 4)
    if offset < table_end.to_int64() ||
      size < 8L ||
      offset + size > data.length().to_int64() ||
      tags.contains(tag) {
      raise InvalidDocument("Invalid ICC tag bounds or duplicate tag")
    }
    tags[tag] = data[offset.to_int():(offset + size).to_int()]
  }
  // The pipeline always uses the media-relative colorimetric intent.
  if tags.get(b"D2B1") is Some(mpe) {
    let has_matrix_fallback = if gray {
      tags.contains(b"kTRC")
    } else {
      [b"rTRC", b"gTRC", b"bTRC", b"rXYZ", b"gXYZ", b"bXYZ"].all(tag => {
        tags.contains(tag)
      })
    }
    try icc_mpe_transform(mpe, gray, lab) catch {
      Unsupported(_) if tags.contains(b"A2B1") ||
        tags.contains(b"A2B0") ||
        (!lab && has_matrix_fallback) => ()
      error => raise error
    } noraise {
      transform => return transform
    }
  }
  let lookup = match tags.get(b"A2B1") {
    Some(lut) => Some(lut)
    None => tags.get(b"A2B0")
  }
  if lookup is Some(lut) {
    if lut[:4] == b"mAB "[:] {
      return icc_mab_transform(lut, gray, lab)
    }
    return icc_lut_transform(lut, gray, lab)
  }
  if lab {
    raise Unsupported("Unsupported ICC color conversion tags")
  }
  fn tag(key : Bytes) -> BytesView raise OraError {
    match tags.get(key) {
      Some(value) => value
      None =>
        raise Unsupported("ICC is missing a required matrix or tone curve tag")
    }
  }
  if gray {
    let curve = icc_curve(tag(b"kTRC"))
    return fn(r, _, _) {
      let value = encode_srgb(curve(r))
      (value, value, value)
    }
  }
  let r = icc_curve(tag(b"rTRC"))
  let g = icc_curve(tag(b"gTRC"))
  let b = icc_curve(tag(b"bTRC"))
  let red = icc_xyz(tag(b"rXYZ"))
  let green = icc_xyz(tag(b"gXYZ"))
  let blue = icc_xyz(tag(b"bXYZ"))
  fn(a, c, d) {
    let a = r(a).max(0.0).min(1.0)
    let c = g(c).max(0.0).min(1.0)
    let d = b(d).max(0.0).min(1.0)
    let x = red.0 * a + green.0 * c + blue.0 * d
    let y = red.1 * a + green.1 * c + blue.1 * d
    let z = red.2 * a + green.2 * c + blue.2 * d
    icc_xyz_srgb(x, y, z)
  }
}
