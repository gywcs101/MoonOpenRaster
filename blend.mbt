///|
fn lum(c : Array[Double]) -> Double {
  0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
}

///|
fn sat(c : Array[Double]) -> Double {
  c[0].max(c[1]).max(c[2]) - c[0].min(c[1]).min(c[2])
}

///|
fn set_lum(c : Array[Double], l : Double) -> Array[Double] {
  let d = l - lum(c)
  let r = c.map(fn(v) { v + d })
  let n = r[0].min(r[1]).min(r[2])
  let x = r[0].max(r[1]).max(r[2])
  if n < 0.0 {
    for i in 0..<3 {
      r[i] = l + (r[i] - l) * l / (l - n)
    }
  }
  if x > 1.0 {
    for i in 0..<3 {
      r[i] = l + (r[i] - l) * (1.0 - l) / (x - l)
    }
  }
  r
}

///|
fn set_sat(c : Array[Double], s : Double) -> Array[Double] {
  let lo = c[0].min(c[1]).min(c[2])
  let hi = c[0].max(c[1]).max(c[2])
  if hi == lo {
    [0.0, 0.0, 0.0]
  } else {
    c.map(fn(v) { (v - lo) * s / (hi - lo) })
  }
}

///|
fn channel(b : Double, s : Double, op : String) -> Double {
  match op {
    "svg:multiply" => b * s
    "svg:screen" => b + s - b * s
    "svg:overlay" =>
      if b <= 0.5 {
        2.0 * b * s
      } else {
        1.0 - 2.0 * (1.0 - b) * (1.0 - s)
      }
    "svg:darken" => b.min(s)
    "svg:lighten" => b.max(s)
    "svg:color-dodge" =>
      if b == 0.0 {
        0.0
      } else if s == 1.0 {
        1.0
      } else {
        (b / (1.0 - s)).min(1.0)
      }
    "svg:color-burn" =>
      if b == 1.0 {
        1.0
      } else if s == 0.0 {
        0.0
      } else {
        1.0 - ((1.0 - b) / s).min(1.0)
      }
    "svg:hard-light" =>
      if s <= 0.5 {
        2.0 * b * s
      } else {
        1.0 - 2.0 * (1.0 - b) * (1.0 - s)
      }
    "svg:soft-light" =>
      if s <= 0.5 {
        b - (1.0 - 2.0 * s) * b * (1.0 - b)
      } else {
        let d = if b <= 0.25 {
          ((16.0 * b - 12.0) * b + 4.0) * b
        } else {
          b.sqrt()
        }
        b + (2.0 * s - 1.0) * (d - b)
      }
    "svg:difference" => (b - s).abs()
    _ => s
  }
}

///|
pub fn composite_pixel(
  backdrop : Array[Double],
  source : Array[Double],
  op : String,
) -> Array[Double] raise OraError {
  if backdrop.length() != 4 || source.length() != 4 {
    raise InvalidDocument("Pixel requires four channels")
  }
  for
    v in [
      backdrop[0],
      backdrop[1],
      backdrop[2],
      backdrop[3],
      source[0],
      source[1],
      source[2],
      source[3],
    ] {
    if v.is_nan() || v < 0.0 || v > 1.0 {
      raise InvalidDocument("Pixel channels must be finite in [0,1]")
    }
  }
  let ab = backdrop[3]
  let a = source[3]
  let blend = match op {
    "svg:hue" => set_lum(set_sat(source, sat(backdrop)), lum(backdrop))
    "svg:saturation" => set_lum(set_sat(backdrop, sat(source)), lum(backdrop))
    "svg:color" => set_lum(source, lum(backdrop))
    "svg:luminosity" => set_lum(backdrop, lum(source))
    "svg:src-over"
    | "svg:multiply"
    | "svg:screen"
    | "svg:overlay"
    | "svg:darken"
    | "svg:lighten"
    | "svg:color-dodge"
    | "svg:color-burn"
    | "svg:hard-light"
    | "svg:soft-light"
    | "svg:difference"
    | "svg:plus"
    | "svg:dst-in"
    | "svg:dst-out"
    | "svg:src-atop"
    | "svg:dst-atop" =>
      [
        channel(backdrop[0], source[0], op),
        channel(backdrop[1], source[1], op),
        channel(backdrop[2], source[2], op),
      ]
    _ => raise Unsupported("Unknown composite operation: " + op)
  }
  let (fa, fb) = match op {
    "svg:dst-in" => (0.0, a)
    "svg:dst-out" => (0.0, 1.0 - a)
    "svg:src-atop" => (ab, 1.0 - a)
    "svg:dst-atop" => (1.0 - ab, a)
    "svg:plus" => (1.0, 1.0)
    _ => (1.0, 1.0 - a)
  }
  let alpha = (a * fa + ab * fb).min(1.0)
  let out = [0.0, 0.0, 0.0, alpha]
  if alpha > 0.0 {
    for i in 0..<3 {
      let cs = if op == "svg:plus" ||
        op == "svg:dst-in" ||
        op == "svg:dst-out" ||
        op == "svg:src-atop" ||
        op == "svg:dst-atop" {
        source[i]
      } else {
        (1.0 - ab) * source[i] + ab * blend[i]
      }
      out[i] = ((a * fa * cs + ab * fb * backdrop[i]).min(1.0) / alpha)
        .max(0.0)
        .min(1.0)
    }
  }
  out
}
