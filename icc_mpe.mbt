///|
fn icc_read_floats(
  data : BytesView,
  first : Int32,
) -> Array[Double] raise OraError {
  let values : Array[Double] = []
  for at = first; at + 4 <= data.length(); at = at + 4 {
    let bits = icc_uint(data, at, 4).to_uint()
    let value = Float::reinterpret_from_uint(bits).to_double()
    guard !value.is_nan() && value.abs() <= 1000000.0 else {
      raise Unsupported("ICC multi-process value is out of range")
    }
    values.push(value)
  }
  values
}

///|
fn icc_mpe_curve(data : BytesView) -> ((Double) -> Double) raise OraError {
  guard data.length() >= 12 && data[:4] == b"curf"[:] else {
    raise InvalidDocument("Invalid ICC segmented curve")
  }
  let count = icc_uint(data, 8, 2).to_int()
  let first_segment = 12 + (count - 1) * 4
  guard count >= 1 && count <= 64 && first_segment <= data.length() else {
    raise InvalidDocument("Invalid ICC segmented curve breakpoint table")
  }
  let breaks = icc_read_floats(data[:first_segment], 12)
  for i in 1..<breaks.length() {
    guard breaks[i - 1] < breaks[i] else {
      raise InvalidDocument("Unsorted ICC segmented curve breakpoints")
    }
  }
  let segments : Array[(Double) -> Double] = []
  let mut start = first_segment
  for i in 0..<count {
    guard start + 12 <= data.length() else {
      raise InvalidDocument("Truncated ICC segmented curve")
    }
    match data[start:start + 4].to_owned() {
      b"parf" => {
        let kind = icc_uint(data, start + 8, 2).to_int()
        let size = match kind {
          0 => 28
          1 | 2 => 32
          _ => raise Unsupported("Unsupported ICC segmented curve formula")
        }
        guard start + size <= data.length() else {
          raise InvalidDocument("Truncated ICC segmented curve formula")
        }
        let p = icc_read_floats(data[:start + size], start + 12)
        segments.push(
          match kind {
            0 => x => @math.pow(p[1] * x + p[2], p[0]) + p[3]
            1 =>
              x => p[1] * @math.log10(p[2] * @math.pow(x, p[0]) + p[3]) + p[4]
            _ => x => p[0] * @math.pow(p[1], p[2] * x + p[3]) + p[4]
          },
        )
        start += size
      }
      b"samf" => {
        let samples = icc_uint(data, start + 8, 4)
        guard i > 0 &&
          i < count - 1 &&
          samples > 0L &&
          samples * 4L <= (data.length() - start - 12).to_int64() else {
          raise InvalidDocument("Invalid ICC segmented curve samples")
        }
        let size = 12 + samples.to_int() * 4
        let values = icc_read_floats(data[:start + size], start + 12)
        let low = breaks[i - 1]
        let high = breaks[i]
        let lower_sample = segments[i - 1](low)
        segments.push(x => {
          let position = ((x - low) / (high - low)).max(0.0).min(1.0) *
            values.length().to_double()
          let point = position.to_int().min(values.length() - 1)
          let previous = if point == 0 {
            lower_sample
          } else {
            values[point - 1]
          }
          previous + (values[point] - previous) * (position - point.to_double())
        })
        start += size
      }
      _ => raise Unsupported("Unsupported ICC segmented curve encoding")
    }
  }
  guard start == data.length() else {
    raise InvalidDocument("Invalid ICC segmented curve length")
  }
  fn(value) {
    for i, boundary in breaks {
      if value <= boundary {
        return segments[i](value)
      }
    }
    segments[breaks.length()](value)
  }
}

///|
fn icc_mpe_stage(
  data : BytesView,
  inputs : Int32,
  outputs : Int32,
) -> ((Array[Double]) -> Array[Double]) raise OraError {
  if data[:4] == b"matf"[:] {
    guard data.length() == 12 + 4 * outputs * (inputs + 1) else {
      raise InvalidDocument("Invalid ICC multi-process matrix size")
    }
    let coefficients = icc_read_floats(data, 12)
    return input => {
      Array::makei(outputs, row => {
        let mut value = coefficients[inputs * outputs + row]
        for column in 0..<inputs {
          value += coefficients[row * inputs + column] * input[column]
        }
        value
      })
    }
  }
  if data[:4] == b"clut"[:] {
    guard data.length() >= 28 else {
      raise InvalidDocument("Invalid ICC multi-process table header")
    }
    let grid = Array::makei(inputs, i => data[12 + i].to_int())
    let mut count = outputs * 4
    for points in grid {
      guard points >= 2 else {
        raise InvalidDocument("Invalid ICC multi-process table grid")
      }
      count *= points
    }
    guard data.length() == 28 + count else {
      raise InvalidDocument("Invalid ICC multi-process table size")
    }
    let table = icc_read_floats(data, 28)
    return input => icc_interpolate_grid(input, grid, i => table[i], outputs~)
  }
  if data[:4] == b"cvst"[:] {
    let table_end = 12 + 8 * inputs
    guard inputs == outputs && data.length() >= table_end else {
      raise InvalidDocument("Invalid ICC curve set header")
    }
    let curves : Array[(Double) -> Double] = []
    for channel in 0..<inputs {
      let at = 12 + channel * 8
      let offset = icc_uint(data, at, 4)
      let size = icc_uint(data, at + 4, 4)
      guard offset >= table_end.to_int64() &&
        offset % 4L == 0L &&
        size >= 12L &&
        offset + size <= data.length().to_int64() else {
        raise InvalidDocument("Invalid ICC curve set element bounds")
      }
      curves.push(icc_mpe_curve(data[offset.to_int():(offset + size).to_int()]))
    }
    return input => Array::makei(outputs, i => curves[i](input[i]))
  }
  if data[:4] == b"bACS"[:] || data[:4] == b"eACS"[:] {
    guard inputs == outputs && data.length() == 16 else {
      raise InvalidDocument("Invalid ICC multi-process extension element")
    }
    return input => input
  }
  raise Unsupported("Unsupported ICC multi-process element")
}

///|
fn icc_mpe_transform(
  data : BytesView,
  gray : Bool,
  lab : Bool,
) -> ((Double, Double, Double) -> (Double, Double, Double)) raise OraError {
  let channels = if gray { 1 } else { 3 }
  guard data.length() >= 16 &&
    data[:4] == b"mpet"[:] &&
    icc_uint(data, 8, 2) == channels.to_int64() &&
    icc_uint(data, 10, 2) == 3L else {
    raise InvalidDocument("Invalid ICC multi-process header")
  }
  let count = icc_uint(data, 12, 4)
  guard count >= 1L &&
    count <= 16L &&
    16L + count * 8L <= data.length().to_int64() else {
    raise InvalidDocument("Invalid ICC multi-process element table")
  }
  let stages : Array[(Array[Double]) -> Array[Double]] = []
  let mut input_channels = channels
  for index in 0..<count.to_int() {
    let at = 16 + index * 8
    let offset = icc_uint(data, at, 4)
    let size = icc_uint(data, at + 4, 4)
    guard offset >= 16L + count * 8L &&
      offset % 4L == 0L &&
      size >= 12L &&
      offset + size <= data.length().to_int64() else {
      raise InvalidDocument("Invalid ICC multi-process element bounds")
    }
    let stage = data[offset.to_int():(offset + size).to_int()]
    let output_channels = icc_uint(stage, 10, 2).to_int()
    guard icc_uint(stage, 8, 2) == input_channels.to_int64() &&
      output_channels >= 1 &&
      output_channels <= 3 else {
      raise InvalidDocument("Invalid ICC multi-process channel count")
    }
    stages.push(icc_mpe_stage(stage, input_channels, output_channels))
    input_channels = output_channels
  }
  guard input_channels == 3 else {
    raise InvalidDocument(
      "ICC multi-process transform must produce three PCS channels",
    )
  }
  fn(r, g, b) {
    let mut input = [r, g, b]
    for stage in stages {
      input = stage(input)
      for value in input {
        if value.is_nan() || value.abs() > 3.402823466e38 {
          return (value, value, value)
        }
      }
    }
    if lab {
      icc_lab_srgb(input[0], input[1], input[2])
    } else {
      icc_xyz_srgb(input[0], input[1], input[2])
    }
  }
}
