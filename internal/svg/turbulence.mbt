///|
priv struct NoiseLattice {
  permutation : FixedArray[Int32]
  gradients : FixedArray[(Double, Double)]
}

///|
// SVG 1.1 specifies a Park–Miller sequence and a 256-point lattice per channel.
// https://www.w3.org/TR/SVG11/filters.html#feTurbulenceElement
fn NoiseLattice::new(seed : Double) -> NoiseLattice {
  let modulus = 2147483647L
  let seed = seed.to_int64()
  let mut state = if seed <= 0L {
    1L - seed % (modulus - 1L)
  } else {
    seed.min(modulus - 1L)
  }
  fn sample() -> Int32 {
    state = state * 16807L % modulus
    state.to_int()
  }
  let gradients = FixedArray::makei(1024, _ => {
    let x = (sample() % 512 - 256).to_double()
    let y = (sample() % 512 - 256).to_double()
    let length = (x * x + y * y).sqrt()
    if length == 0.0 {
      (1.0, 0.0)
    } else {
      (x / length, y / length)
    }
  })
  let permutation = FixedArray::makei(256, i => i)
  for i = 255; i > 0; i = i - 1 {
    let other = sample() % 256
    let chosen = permutation[i]
    permutation[i] = permutation[other]
    permutation[other] = chosen
  }
  { permutation, gradients, }
}

///|
priv struct NoiseAxis {
  frequency : Double
  origin : Double
  period : Double
}

///|
fn NoiseAxis::new(
  frequency : Double,
  origin : Double,
  size : Double,
  stitch : Bool,
) -> NoiseAxis {
  let frequency = if frequency.is_finite() { frequency.max(0.0) } else { 0.0 }
  if !stitch || size <= 0.0 || frequency <= 0.0 {
    return { frequency, origin, period: 0.0, }
  }
  let cycles = size * frequency
  let lower = cycles.floor()
  let upper = cycles.ceil()
  let period = if lower > 0.0 && cycles / lower < upper / cycles {
    lower
  } else {
    upper
  }
  { frequency: period / size, origin, period, }
}

///|
fn NoiseAxis::coordinates(
  self : NoiseAxis,
  at : Double,
  scale : Double,
) -> (Int32, Int32, Double) {
  let sample = at * self.frequency * scale
  let grid = sample.floor()
  let first = if self.period > 0.0 {
    let start = (self.origin * self.frequency * scale).floor()
    let period = self.period * scale
    let distance = grid - start
    let wrapped = distance - (distance / period).floor() * period
    start + wrapped
  } else {
    grid
  }
  let second = if self.period > 0.0 &&
    first + 1.0 >=
    (self.origin * self.frequency * scale).floor() + self.period * scale {
    first + 1.0 - self.period * scale
  } else {
    first + 1.0
  }
  // Reduce before converting to a machine integer, even on large viewports.
  fn index(value : Double) -> Int32 {
    (value - (value / 256.0).floor() * 256.0).to_int() & 255
  }
  (index(first), index(second), sample - grid)
}

///|
fn NoiseLattice::sample_at(
  self : NoiseLattice,
  channel : Int32,
  x : (Int32, Int32, Double),
  y : (Int32, Int32, Double),
) -> Double {
  let (x0, x1, dx) = x
  let (y0, y1, dy) = y
  fn projection(
    ix : Int32,
    iy : Int32,
    offset_x : Double,
    offset_y : Double,
  ) -> Double {
    let slot = self.permutation[(self.permutation[ix] + iy) & 255]
    let (vx, vy) = self.gradients[channel * 256 + slot]
    vx * offset_x + vy * offset_y
  }
  let top_left = projection(x0, y0, dx, dy)
  let top_right = projection(x1, y0, dx - 1.0, dy)
  let bottom_left = projection(x0, y1, dx, dy - 1.0)
  let bottom_right = projection(x1, y1, dx - 1.0, dy - 1.0)
  let sx = dx * dx * (3.0 - 2.0 * dx)
  let sy = dy * dy * (3.0 - 2.0 * dy)
  let top = top_left + sx * (top_right - top_left)
  let bottom = bottom_left + sx * (bottom_right - bottom_left)
  top + sy * (bottom - top)
}

///|
fn turbulence_filter_image(
  width : Int32,
  height : Int32,
  base_x : Double,
  base_y : Double,
  octaves : Int32,
  seed : Double,
  stitch : Bool,
  fractal_noise : Bool,
  tile : BoundingBox,
  origin_x : Int32,
  origin_y : Int32,
  linear_rgb : Bool,
) -> Image {
  let result = Image::new(width, height)
  let lattice = NoiseLattice::new(seed)
  let horizontal = NoiseAxis::new(
    base_x,
    tile.min_x + origin_x.to_double(),
    tile.width(),
    stitch,
  )
  let vertical = NoiseAxis::new(
    base_y,
    tile.min_y + origin_y.to_double(),
    tile.height(),
    stitch,
  )
  let count = octaves.max(0).min(12)
  let channels = FixedArray::make(4, 0.0)
  for y in 0..<height {
    for x in 0..<width {
      let point_x = (x + origin_x).to_double() + 1.0
      let point_y = (y + origin_y).to_double() + 1.0
      for channel in 0..<4 {
        channels[channel] = 0.0
      }
      let mut scale = 1.0
      for _ in 0..<count {
        let xs = horizontal.coordinates(point_x, scale)
        let ys = vertical.coordinates(point_y, scale)
        for channel in 0..<4 {
          let noise = lattice.sample_at(channel, xs, ys)
          channels[channel] += (if fractal_noise { noise } else { noise.abs() }) /
            scale
        }
        scale *= 2.0
      }
      fn value(channel : Int32) -> Int32 {
        let raw = channels[channel]
        let normalized = if fractal_noise { 0.5 + raw / 2.0 } else { raw }
        filter_output_channel(normalized, channel < 3 && linear_rgb)
      }
      result.set_pixel(
        x,
        y,
        Color::rgba(value(0), value(1), value(2), value(3)),
      )
    }
  }
  result
}
