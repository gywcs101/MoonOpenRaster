///|
fn filter_source_alpha(source : Image) -> Image {
  let result = Image::new(source.width, source.height)
  for y in 0..<source.height {
    for x in 0..<source.width {
      let alpha = source.get_pixel(x, y).a
      if alpha > 0 {
        result.set_pixel(x, y, Color::rgba(0, 0, 0, alpha))
      }
    }
  }
  result
}

///|
fn filter_input_channel(value : Int32, linear_rgb : Bool) -> Double {
  let unit = value.to_double() / 255.0
  if linear_rgb {
    srgb_to_linear_unit(unit)
  } else {
    unit
  }
}

///|
fn filter_output_channel(value : Double, linear_rgb : Bool) -> Int32 {
  let unit = clamp_filter_unit(value)
  let encoded = if linear_rgb { linear_to_srgb_unit(unit) } else { unit }
  (encoded * 255.0).round().to_int()
}

///|
fn offset_filter_image(source : Image, dx : Double, dy : Double) -> Image {
  let result = Image::new(source.width, source.height)
  let offset_x = dx.round().to_int()
  let offset_y = dy.round().to_int()
  if dx != offset_x.to_double() || dy != offset_y.to_double() {
    let base_x = (-dx).floor().to_int()
    let base_y = (-dy).floor().to_int()
    let mix_x = -dx - base_x.to_double()
    let mix_y = -dy - base_y.to_double()
    let corners = [
      (0, 0, (1.0 - mix_x) * (1.0 - mix_y)),
      (1, 0, mix_x * (1.0 - mix_y)),
      (0, 1, (1.0 - mix_x) * mix_y),
      (1, 1, mix_x * mix_y),
    ]
    for y in 0..<source.height {
      for x in 0..<source.width {
        let mut red = 0.0
        let mut green = 0.0
        let mut blue = 0.0
        let mut alpha = 0.0
        for (ox, oy, weight) in corners {
          let color = PremulColor16::from_color(
            source.get_pixel(x + base_x + ox, y + base_y + oy),
          )
          red += color.r.to_double() * weight
          green += color.g.to_double() * weight
          blue += color.b.to_double() * weight
          alpha += color.a.to_double() * weight
        }
        result.set_pixel(x, y, sampled_premul_color(red, green, blue, alpha))
      }
    }
    return result
  }
  for y in 0..<source.height {
    for x in 0..<source.width {
      let color = source.get_pixel(x, y)
      if color.a > 0 {
        result.set_pixel(x + offset_x, y + offset_y, color)
      }
    }
  }
  result
}

///|
// Modified in MoonOpenRaster: separable SVG Gaussian blur on premultiplied samples.
// For larger deviations SVG 1.1 permits the three-box approximation.
fn gaussian_blur_axis(
  values : FixedArray[Float],
  scratch : FixedArray[Float],
  lines : Int32,
  span : Int32,
  step : Int32,
  line_step : Int32,
  sigma : Double,
) -> (FixedArray[Float], FixedArray[Float]) {
  if sigma <= 0.0 || !sigma.is_finite() {
    return (values, scratch)
  }
  if sigma < 2.0 {
    let radius = (3.0 * sigma).ceil().to_int()
    let kernel = Array::makei(radius * 2 + 1, i => {
      let z = (i - radius).to_double() / sigma
      @math.exp(-0.5 * z * z)
    })
    let total = kernel.fold(init=0.0, (sum, sample) => sum + sample)
    for line in 0..<lines {
      let start = line * line_step
      for index in 0..<span {
        let mut sum = 0.0
        let first = (-radius).max(-index)
        let last = radius.min(span - index - 1)
        for offset in first..<=last {
          let position = start + (index + offset) * step
          sum += values[position].to_double() * kernel[offset + radius]
        }
        scratch[start + index * step] = Float::from_double(sum / total)
      }
    }
    return (scratch, values)
  }
  let diameter = (sigma.min(1000000.0) * 1.8799712059732503 + 0.5)
    .floor()
    .to_int()
  let half = diameter / 2
  let stages = if diameter % 2 == 1 {
    [(half, half), (half, half), (half, half)]
  } else {
    [(half, half - 1), (half - 1, half), (half, half)]
  }
  let mut source = values
  let mut target = scratch
  for (left, right) in stages {
    let divisor = (left + right + 1).to_double()
    for line in 0..<lines {
      let start = line * line_step
      let mut sum = 0.0
      for position in 0..<span.min(right + 1) {
        sum += source[start + position * step].to_double()
      }
      for index in 0..<span {
        target[start + index * step] = Float::from_double(sum / divisor)
        if index >= left {
          sum -= source[start + (index - left) * step].to_double()
        }
        let incoming = index + right + 1
        if incoming < span {
          sum += source[start + incoming * step].to_double()
        }
      }
    }
    let previous = source
    source = target
    target = previous
  }
  (source, target)
}

///|
fn blur_filter_image_xy(
  source : Image,
  radius_x : Double,
  radius_y : Double,
  linear_rgb : Bool,
) -> Image {
  if radius_x <= 0.0 && radius_y <= 0.0 {
    return source
  }
  let width = source.width
  let height = source.height
  let result = Image::new(width, height)
  let alpha = FixedArray::make(width * height, (0.0 : Float))
  let mut plane = FixedArray::make(width * height, (0.0 : Float))
  let mut scratch = FixedArray::make(width * height, (0.0 : Float))
  for channel in [3, 0, 1, 2] {
    for y in 0..<height {
      for x in 0..<width {
        let color = source.get_pixel(x, y)
        let value = match channel {
          3 => color.a.to_double()
          0 => filter_input_channel(color.r, linear_rgb) * color.a.to_double()
          1 => filter_input_channel(color.g, linear_rgb) * color.a.to_double()
          _ => filter_input_channel(color.b, linear_rgb) * color.a.to_double()
        }
        plane[y * width + x] = Float::from_double(value)
      }
    }
    let (horizontal, spare) = gaussian_blur_axis(
      plane, scratch, height, width, 1, width, radius_x,
    )
    let (filtered, spare) = gaussian_blur_axis(
      horizontal, spare, width, height, width, 1, radius_y,
    )
    for y in 0..<height {
      for x in 0..<width {
        let index = y * width + x
        let value = filtered[index].to_double()
        if channel == 3 {
          alpha[index] = filtered[index]
          result.set_pixel(x, y, Color::rgba(0, 0, 0, value.round().to_int()))
        } else if alpha[index] > (0.0 : Float) {
          let component = filter_output_channel(
            value / alpha[index].to_double(),
            linear_rgb,
          )
          let color = result.get_pixel(x, y)
          result.set_pixel(
            x,
            y,
            Color::rgba(
              if channel == 0 {
                component
              } else {
                color.r
              },
              if channel == 1 {
                component
              } else {
                color.g
              },
              if channel == 2 {
                component
              } else {
                color.b
              },
              color.a,
            ),
          )
        }
      }
    }
    plane = filtered
    scratch = spare
  }
  result
}

///|
fn transfer_filter_value(
  function : ComponentTransferFunction,
  value : Double,
) -> Double {
  match function {
    TransferIdentity => value
    TransferTable(values) => {
      if values.length() == 0 {
        return value
      }
      if values.length() == 1 {
        return clamp_filter_unit(values[0])
      }
      let position = clamp_filter_unit(value) *
        (values.length() - 1).to_double()
      let lower = position.floor().to_int()
      let upper = if lower + 1 < values.length() { lower + 1 } else { lower }
      let fraction = position - lower.to_double()
      clamp_filter_unit(
        values[lower] * (1.0 - fraction) + values[upper] * fraction,
      )
    }
    TransferDiscrete(values) => {
      if values.length() == 0 {
        return value
      }
      let mut index = (clamp_filter_unit(value) * values.length().to_double())
        .floor()
        .to_int()
      if index >= values.length() {
        index = values.length() - 1
      }
      clamp_filter_unit(values[index])
    }
    TransferLinear(slope~, intercept~) =>
      clamp_filter_unit(slope * value + intercept)
    TransferGamma(amplitude~, exponent~, offset~) =>
      clamp_filter_unit(amplitude * @math.pow(value, exponent) + offset)
  }
}

///|
fn component_transfer_filter_image(
  source : Image,
  red : ComponentTransferFunction,
  green : ComponentTransferFunction,
  blue : ComponentTransferFunction,
  alpha : ComponentTransferFunction,
  linear_rgb : Bool,
) -> Image {
  let result = Image::new(source.width, source.height)
  for y in 0..<source.height {
    for x in 0..<source.width {
      let color = source.get_pixel(x, y)
      result.set_pixel(
        x,
        y,
        Color::rgba(
          filter_output_channel(
            transfer_filter_value(
              red,
              filter_input_channel(color.r, linear_rgb),
            ),
            linear_rgb,
          ),
          filter_output_channel(
            transfer_filter_value(
              green,
              filter_input_channel(color.g, linear_rgb),
            ),
            linear_rgb,
          ),
          filter_output_channel(
            transfer_filter_value(
              blue,
              filter_input_channel(color.b, linear_rgb),
            ),
            linear_rgb,
          ),
          (transfer_filter_value(alpha, color.a.to_double() / 255.0) * 255.0)
          .round()
          .to_int(),
        ),
      )
    }
  }
  result
}

///|
fn morphology_filter_image(
  source : Image,
  radius_x : Double,
  radius_y : Double,
  operator : MorphologyOperator,
  linear_rgb : Bool,
) -> Image {
  let rx = ceil_to_int(if radius_x < 0.0 { 0.0 } else { radius_x })
  let ry = ceil_to_int(if radius_y < 0.0 { 0.0 } else { radius_y })
  let result = Image::new(source.width, source.height)
  let working = if linear_rgb { LinearRGB } else { SRGB }
  let (initial, order) : (Int32, (Int32, Int32) -> Int32) = if operator ==
    MorphologyDilate {
    (0, (a, b) => a.max(b))
  } else {
    (65535, (a, b) => a.min(b))
  }
  for y in 0..<source.height {
    for x in 0..<source.width {
      let mut r = initial
      let mut g = initial
      let mut b = initial
      let mut a = initial
      for offset_y in -ry..<=ry {
        for offset_x in -rx..<=rx {
          let color = PremulColor16::from_color(
            source.get_pixel(x + offset_x, y + offset_y),
          ).convert_space(SRGB, working)
          r = order(r, color.r)
          g = order(g, color.g)
          b = order(b, color.b)
          a = order(a, color.a)
        }
      }
      let pixel : PremulColor16 = { r, g, b, a, }
      result.set_pixel(x, y, pixel.convert_space(working, SRGB).to_color())
    }
  }
  result
}

///|
fn convolve_sample(
  source : Image,
  x : Int32,
  y : Int32,
  edge_mode : FilterEdgeMode,
) -> Color {
  if x >= 0 && x < source.width && y >= 0 && y < source.height {
    return source.get_pixel(x, y)
  }
  match edge_mode {
    EdgeNone => Color::transparent()
    EdgeDuplicate => {
      let sample_x = if x < 0 {
        0
      } else if x >= source.width {
        source.width - 1
      } else {
        x
      }
      let sample_y = if y < 0 {
        0
      } else if y >= source.height {
        source.height - 1
      } else {
        y
      }
      source.get_pixel(sample_x, sample_y)
    }
    EdgeWrap => {
      let mut sample_x = x % source.width
      let mut sample_y = y % source.height
      if sample_x < 0 {
        sample_x = sample_x + source.width
      }
      if sample_y < 0 {
        sample_y = sample_y + source.height
      }
      source.get_pixel(sample_x, sample_y)
    }
  }
}

///|
fn convolve_filter_image(
  source : Image,
  order_x : Int32,
  order_y : Int32,
  kernel : Array[Double],
  divisor : Double,
  bias : Double,
  target_x : Int32,
  target_y : Int32,
  edge_mode : FilterEdgeMode,
  preserve_alpha : Bool,
  linear_rgb : Bool,
) -> Image {
  if order_x <= 0 || order_y <= 0 || kernel.length() != order_x * order_y {
    return source
  }
  let safe_divisor = if divisor.abs() <= 0.000001 { 1.0 } else { divisor }
  let result = Image::new(source.width, source.height)
  for y in 0..<source.height {
    for x in 0..<source.width {
      let mut red = 0.0
      let mut green = 0.0
      let mut blue = 0.0
      let mut alpha = 0.0
      for kernel_y in 0..<order_y {
        for kernel_x in 0..<order_x {
          let sample = convolve_sample(
            source,
            x + kernel_x - target_x,
            y + kernel_y - target_y,
            edge_mode,
          )
          let weight = kernel[(order_y - 1 - kernel_y) * order_x +
            order_x -
            1 -
            kernel_x]
          let sample_alpha = sample.a.to_double() / 255.0
          let color_weight = if preserve_alpha {
            weight
          } else {
            weight * sample_alpha
          }
          red += filter_input_channel(sample.r, linear_rgb) * color_weight
          green += filter_input_channel(sample.g, linear_rgb) * color_weight
          blue += filter_input_channel(sample.b, linear_rgb) * color_weight
          alpha += sample_alpha * weight
        }
      }
      let opacity = if preserve_alpha {
        source.get_pixel(x, y).a.to_double() / 255.0
      } else {
        clamp_filter_unit(alpha / safe_divisor + bias)
      }
      fn output_channel(value : Double) -> Int32 {
        let component = if preserve_alpha {
          value / safe_divisor + bias
        } else if opacity > 0.0 {
          value / (safe_divisor * opacity) + bias
        } else {
          0.0
        }
        filter_output_channel(component, linear_rgb)
      }
      result.set_pixel(
        x,
        y,
        Color::rgba(
          output_channel(red),
          output_channel(green),
          output_channel(blue),
          (opacity * 255.0).round().to_int(),
        ),
      )
    }
  }
  result
}

///|
fn filter_channel_value(
  color : Color,
  channel : FilterChannel,
  linear_rgb : Bool,
) -> Double {
  match channel {
    ChannelR => filter_input_channel(color.r, linear_rgb)
    ChannelG => filter_input_channel(color.g, linear_rgb)
    ChannelB => filter_input_channel(color.b, linear_rgb)
    ChannelA => filter_input_channel(color.a, false)
  }
}

///|
fn displacement_filter_image(
  source : Image,
  displacement : Image,
  displacement_transform : Transform,
  x_channel : FilterChannel,
  y_channel : FilterChannel,
  linear_rgb : Bool,
) -> Image {
  let result = Image::new(source.width, source.height)
  for y in 0..<source.height {
    for x in 0..<source.width {
      let map_color = displacement.get_pixel(x, y)
      let (dx, dy) = displacement_transform.apply(
        filter_channel_value(map_color, x_channel, linear_rgb) - 0.5,
        filter_channel_value(map_color, y_channel, linear_rgb) - 0.5,
      )
      let source_x = x.to_double() + dx
      let source_y = y.to_double() + dy
      result.set_pixel(
        x,
        y,
        source.get_pixel(source_x.round().to_int(), source_y.round().to_int()),
      )
    }
  }
  result
}

///|
fn tile_filter_image(source : Image, bounds : BoundingBox) -> Image {
  let result = Image::new(source.width, source.height)
  let min_x = floor_to_int(bounds.min_x)
  let min_y = floor_to_int(bounds.min_y)
  let width = ceil_to_int(bounds.max_x) - min_x
  let height = ceil_to_int(bounds.max_y) - min_y
  if width <= 0 || height <= 0 {
    return result
  }
  for y in 0..<source.height {
    for x in 0..<source.width {
      let sample_x = min_x + ((x - min_x) % width + width) % width
      let sample_y = min_y + ((y - min_y) % height + height) % height
      result.set_pixel(x, y, source.get_pixel(sample_x, sample_y))
    }
  }
  result
}

///|
fn filter_image_resource(
  width : Int32,
  height : Int32,
  href : String,
  display : BoundingBox,
  aspect : PreserveAspectRatio,
  resolver : ((String) -> Image?)?,
) -> Image? {
  guard resolver is Some(resolve) && resolve(href) is Some(image) else {
    return None
  }
  let result = Image::new(width, height)
  let ctx = RenderState::new(
    make_image_compositing_setter(result),
    width,
    height,
  )
  render_raster_image(
    image,
    display.min_x,
    display.min_y,
    display.width(),
    display.height(),
    Transform::identity(),
    ctx,
    aspect,
    Bilinear,
    1.0,
  )
  Some(result)
}

///|
fn normalize_filter_vector(
  x : Double,
  y : Double,
  z : Double,
) -> (Double, Double, Double) {
  let length = (x * x + y * y + z * z).sqrt()
  if length <= 0.000001 {
    (0.0, 0.0, 1.0)
  } else {
    (x / length, y / length, z / length)
  }
}

///|
fn filter_light_vector(
  light : FilterLight,
  x : Double,
  y : Double,
  z : Double,
) -> (Double, Double, Double, Double) {
  match light {
    DistantLight(azimuth~, elevation~) => {
      let azimuth_radians = degrees_to_radians(azimuth)
      let elevation_radians = degrees_to_radians(elevation)
      (
        @math.cos(azimuth_radians) * @math.cos(elevation_radians),
        @math.sin(azimuth_radians) * @math.cos(elevation_radians),
        @math.sin(elevation_radians),
        1.0,
      )
    }
    PointLight(x=light_x, y=light_y, z=light_z) => {
      let vector = normalize_filter_vector(
        light_x - x,
        light_y - y,
        light_z - z,
      )
      (vector.0, vector.1, vector.2, 1.0)
    }
    SpotLight(
      x=light_x,
      y=light_y,
      z=light_z,
      points_at_x~,
      points_at_y~,
      points_at_z~,
      exponent~,
      limiting_cone_angle~,
    ) => {
      let vector = normalize_filter_vector(
        light_x - x,
        light_y - y,
        light_z - z,
      )
      let spot_direction = normalize_filter_vector(
        points_at_x - light_x,
        points_at_y - light_y,
        points_at_z - light_z,
      )
      let from_light = (-vector.0, -vector.1, -vector.2)
      let cosine = max(
        0.0,
        from_light.0 * spot_direction.0 +
        from_light.1 * spot_direction.1 +
        from_light.2 * spot_direction.2,
      )
      let inside_cone = match limiting_cone_angle {
        Some(angle) => cosine >= @math.cos(degrees_to_radians(angle))
        None => true
      }
      let attenuation = if inside_cone {
        @math.pow(cosine, exponent)
      } else {
        0.0
      }
      (vector.0, vector.1, vector.2, attenuation)
    }
  }
}

///|
fn lighting_filter_image(
  source : Image,
  surface_scale : Double,
  constant : Double,
  exponent : Double,
  lighting_color : Color,
  light : FilterLight,
  specular : Bool,
  linear_rgb : Bool,
) -> Image {
  let result = Image::new(source.width, source.height)
  let lr = filter_input_channel(lighting_color.r, linear_rgb)
  let lg = filter_input_channel(lighting_color.g, linear_rgb)
  let lb = filter_input_channel(lighting_color.b, linear_rgb)
  for y in 0..<source.height {
    for x in 0..<source.width {
      let height = source.get_pixel(x, y).a.to_double() / 255.0 * surface_scale
      let left = max_int(0, x - 1)
      let right = min_int(source.width - 1, x + 1)
      let top = max_int(0, y - 1)
      let bottom = min_int(source.height - 1, y + 1)
      // SVG's lighting kernel uses one-sided differences at the image edge
      // and weights the center row or column twice.
      let mut dx = 0.0
      let mut dy = 0.0
      for row in top..<=bottom {
        let weight = if row == y { 2.0 } else { 1.0 }
        dx += weight *
          (source.get_pixel(right, row).a - source.get_pixel(left, row).a).to_double()
      }
      for col in left..<=right {
        let weight = if col == x { 2.0 } else { 1.0 }
        dy += weight *
          (source.get_pixel(col, bottom).a - source.get_pixel(col, top).a).to_double()
      }
      let scale = 2.0 * surface_scale / 255.0
      dx *= scale / ((bottom - top + 2) * max_int(1, right - left)).to_double()
      dy *= scale / ((right - left + 2) * max_int(1, bottom - top)).to_double()
      let normal = normalize_filter_vector(-dx, -dy, 1.0)
      let light_vector = filter_light_vector(
        light,
        x.to_double(),
        y.to_double(),
        height,
      )
      let dot = if specular {
        let half_vector = normalize_filter_vector(
          light_vector.0,
          light_vector.1,
          light_vector.2 + 1.0,
        )
        max(
          0.0,
          normal.0 * half_vector.0 +
          normal.1 * half_vector.1 +
          normal.2 * half_vector.2,
        )
      } else {
        max(
          0.0,
          normal.0 * light_vector.0 +
          normal.1 * light_vector.1 +
          normal.2 * light_vector.2,
        )
      }
      let intensity = constant *
        (if specular { @math.pow(dot, exponent) } else { dot }) *
        light_vector.3
      let red = clamp_filter_unit(lr * intensity)
      let green = clamp_filter_unit(lg * intensity)
      let blue = clamp_filter_unit(lb * intensity)
      let alpha = if specular { max(red, max(green, blue)) } else { 1.0 }
      if alpha > 0.0 {
        result.set_pixel(
          x,
          y,
          Color::rgba(
            filter_output_channel(red / alpha, linear_rgb),
            filter_output_channel(green / alpha, linear_rgb),
            filter_output_channel(blue / alpha, linear_rgb),
            filter_output_channel(alpha, false),
          ),
        )
      }
    }
  }
  result
}

///|
fn filter_primitive_x(
  graph : FilterGraph,
  value : Double,
  target : BoundingBox,
) -> Double {
  match graph.primitive_units {
    ObjectBoundingBox => value * target.width()
    UserSpaceOnUse => value
  }
}

///|
fn filter_primitive_y(
  graph : FilterGraph,
  value : Double,
  target : BoundingBox,
) -> Double {
  match graph.primitive_units {
    ObjectBoundingBox => value * target.height()
    UserSpaceOnUse => value
  }
}

///|
fn filter_primitive_position_x(
  graph : FilterGraph,
  value : Double,
  target : BoundingBox,
  origin_x : Int32,
) -> Double {
  match graph.primitive_units {
    ObjectBoundingBox => target.min_x + value * target.width()
    UserSpaceOnUse => value - origin_x.to_double()
  }
}

///|
fn filter_primitive_position_y(
  graph : FilterGraph,
  value : Double,
  target : BoundingBox,
  origin_y : Int32,
) -> Double {
  match graph.primitive_units {
    ObjectBoundingBox => target.min_y + value * target.height()
    UserSpaceOnUse => value - origin_y.to_double()
  }
}

///|
fn resolve_filter_light(
  graph : FilterGraph,
  light : FilterLight,
  target : BoundingBox,
  origin_x : Int32,
  origin_y : Int32,
) -> FilterLight {
  match light {
    DistantLight(..) => light
    PointLight(x~, y~, z~) =>
      PointLight(
        x=filter_primitive_position_x(graph, x, target, origin_x),
        y=filter_primitive_position_y(graph, y, target, origin_y),
        z=filter_primitive_x(graph, z, target),
      )
    SpotLight(
      x~,
      y~,
      z~,
      points_at_x~,
      points_at_y~,
      points_at_z~,
      exponent~,
      limiting_cone_angle~,
    ) =>
      SpotLight(
        x=filter_primitive_position_x(graph, x, target, origin_x),
        y=filter_primitive_position_y(graph, y, target, origin_y),
        z=filter_primitive_x(graph, z, target),
        points_at_x=filter_primitive_position_x(
          graph, points_at_x, target, origin_x,
        ),
        points_at_y=filter_primitive_position_y(
          graph, points_at_y, target, origin_y,
        ),
        points_at_z=filter_primitive_x(graph, points_at_z, target),
        exponent~,
        limiting_cone_angle~,
      )
  }
}

///|
fn clamp_filter_unit(value : Double) -> Double {
  if value < 0.0 {
    0.0
  } else if value > 1.0 {
    1.0
  } else {
    value
  }
}

///|
fn composite_filter_pixel(
  source : Color,
  backdrop : Color,
  operator : FilterCompositeOperator,
  k1 : Double,
  k2 : Double,
  k3 : Double,
  k4 : Double,
  linear_rgb : Bool,
) -> Color {
  let source_alpha = source.a.to_double() / 255.0
  let backdrop_alpha = backdrop.a.to_double() / 255.0
  let (source_factor, backdrop_factor) = match operator {
    CompositeOver => (1.0, 1.0 - source_alpha)
    CompositeIn => (backdrop_alpha, 0.0)
    CompositeOut => (1.0 - backdrop_alpha, 0.0)
    CompositeAtop => (backdrop_alpha, 1.0 - source_alpha)
    CompositeXor => (1.0 - backdrop_alpha, 1.0 - source_alpha)
    CompositeArithmetic => (0.0, 0.0)
  }
  let output_alpha = if operator == CompositeArithmetic {
    clamp_filter_unit(
      k1 * source_alpha * backdrop_alpha +
      k2 * source_alpha +
      k3 * backdrop_alpha +
      k4,
    )
  } else {
    clamp_filter_unit(
      source_alpha * source_factor + backdrop_alpha * backdrop_factor,
    )
  }
  if output_alpha <= 0.0 {
    return Color::transparent()
  }
  fn channel(source_channel : Int32, backdrop_channel : Int32) -> Int32 {
    let source_premultiplied = filter_input_channel(source_channel, linear_rgb) *
      source_alpha
    let backdrop_premultiplied = filter_input_channel(
        backdrop_channel, linear_rgb,
      ) *
      backdrop_alpha
    let output_premultiplied = if operator == CompositeArithmetic {
      clamp_filter_unit(
        k1 * source_premultiplied * backdrop_premultiplied +
        k2 * source_premultiplied +
        k3 * backdrop_premultiplied +
        k4,
      )
    } else {
      source_premultiplied * source_factor +
      backdrop_premultiplied * backdrop_factor
    }
    filter_output_channel(output_premultiplied / output_alpha, linear_rgb)
  }
  Color::rgba(
    channel(source.r, backdrop.r),
    channel(source.g, backdrop.g),
    channel(source.b, backdrop.b),
    (output_alpha * 255.0).round().to_int(),
  )
}

///|
fn composite_filter_images(
  source : Image,
  backdrop : Image,
  operator : FilterCompositeOperator,
  k1 : Double,
  k2 : Double,
  k3 : Double,
  k4 : Double,
  linear_rgb : Bool,
) -> Image {
  let width = if source.width < backdrop.width {
    source.width
  } else {
    backdrop.width
  }
  let height = if source.height < backdrop.height {
    source.height
  } else {
    backdrop.height
  }
  let result = Image::new(width, height)
  for y in 0..<height {
    for x in 0..<width {
      result.set_pixel(
        x,
        y,
        composite_filter_pixel(
          source.get_pixel(x, y),
          backdrop.get_pixel(x, y),
          operator,
          k1,
          k2,
          k3,
          k4,
          linear_rgb,
        ),
      )
    }
  }
  result
}

///|
fn clip_filter_result(result : Image, bounds : BoundingBox) -> Image {
  let min_x = floor_to_int(bounds.min_x)
  let min_y = floor_to_int(bounds.min_y)
  let max_x = ceil_to_int(bounds.max_x)
  let max_y = ceil_to_int(bounds.max_y)
  for y in 0..<result.height {
    for x in 0..<result.width {
      if x < min_x || x >= max_x || y < min_y || y >= max_y {
        result.set_pixel(x, y, Color::transparent())
      }
    }
  }
  result
}

///|
fn filter_primitive_region(
  region : FilterPrimitiveRegion,
  graph : FilterGraph,
  target : BoundingBox,
  defaults : BoundingBox,
) -> BoundingBox {
  if graph.primitive_units is ObjectBoundingBox {
    fn dimension(
      value : (Double, Bool)?,
      extent : Double,
      start : Double,
      fallback : Double,
    ) -> Double {
      match value {
        Some((fraction, _)) => start + fraction * extent
        None => fallback
      }
    }
    let x = dimension(region.x, target.width(), target.min_x, defaults.min_x)
    let y = dimension(region.y, target.height(), target.min_y, defaults.min_y)
    let width = dimension(region.width, target.width(), 0.0, defaults.width())
    let height = dimension(
      region.height,
      target.height(),
      0.0,
      defaults.height(),
    )
    return BoundingBox::from_rect(x, y, width.max(0.0), height.max(0.0))
  }
  let (w, h) = graph.viewport
  fn length(
    spec : (Double, Bool)?,
    viewport : Double,
    fallback : Double,
  ) -> Double {
    match spec {
      Some((value, percent)) => resolve_mask_size(value, percent, viewport)
      None => fallback
    }
  }
  let x = length(region.x, w, defaults.min_x)
  let y = length(region.y, h, defaults.min_y)
  let width = length(region.width, w, defaults.width())
  let height = length(region.height, h, defaults.height())
  BoundingBox::from_rect(x, y, width.max(0.0), height.max(0.0))
}

///|
fn FilterGraphPrimitive::region_inputs(
  self : FilterGraphPrimitive,
) -> Array[String] {
  match self {
    GraphColorMatrix(input~, ..)
    | GraphGaussianBlur(input~, ..)
    | GraphOffset(input~, ..)
    | GraphComponentTransfer(input~, ..)
    | GraphMorphology(input~, ..)
    | GraphConvolveMatrix(input~, ..)
    | GraphDiffuseLighting(input~, ..)
    | GraphSpecularLighting(input~, ..) => [input]
    GraphBlend(input~, input2~, ..)
    | GraphComposite(input~, input2~, ..)
    | GraphDisplacementMap(input~, input2~, ..) => [input, input2]
    GraphMerge(inputs~, ..) => inputs
    GraphFlood(..) | GraphImage(..) | GraphTurbulence(..) | GraphTile(..) => []
  }
}

///|
fn clip_affine_filter(
  source : Image,
  rect : BoundingBox,
  transform : Transform,
) -> Image {
  let contours = clip_shape_contours(
    Rect(
      x=rect.min_x,
      y=rect.min_y,
      width=rect.width(),
      height=rect.height(),
      rx=0.0,
      ry=0.0,
    ),
    transform,
  )
  let mask = build_coverage_mask(contours, NonZero, source.width, source.height)
  let clipped = Image::new(source.width, source.height)
  for y in mask.origin_y..<(mask.origin_y + mask.height) {
    for x in mask.origin_x..<(mask.origin_x + mask.width) {
      let coverage = mask.get_device(x, y)
      if coverage > 0 {
        clipped.set_pixel(
          x,
          y,
          apply_coverage(source.get_pixel(x, y), coverage),
        )
      }
    }
  }
  clipped
}

///|
fn evaluate_filter_graph(
  graph : FilterGraph,
  source : Image,
  target_bounds : BoundingBox,
  target_local : BoundingBox,
  image_resolver : ((String) -> Image?)?,
  origin_x : Int32,
  origin_y : Int32,
  transform : Transform,
  local_image : (String) -> Image?,
  paint_input : (String) -> Image?,
  diagnostics : Array[RenderDiagnostic],
) -> Image {
  if graph.primitives.is_empty() {
    return Image::new(source.width, source.height)
  }
  let rect = graph.local_filter_bounds(target_local)
  if rect.width() <= 0.0 || rect.height() <= 0.0 {
    return Image::new(source.width, source.height)
  }
  let raster_transform = Transform::translate(
    -origin_x.to_double(),
    -origin_y.to_double(),
  ).multiply(transform)
  let affine_clip = (transform.b != 0.0 || transform.c != 0.0) &&
    (transform.a != 0.0 || transform.d != 0.0)
  let target_bounds = {
    min_x: target_bounds.min_x - origin_x.to_double(),
    min_y: target_bounds.min_y - origin_y.to_double(),
    max_x: target_bounds.max_x - origin_x.to_double(),
    max_y: target_bounds.max_y - origin_y.to_double(),
  }
  let source_alpha = filter_source_alpha(source)
  let named : Map[String, Image] = Map([])
  let paints : Map[String, Image] = Map([])
  let named_regions : Map[String, BoundingBox] = Map([])
  let mut previous = source
  let mut previous_region = rect
  let (scale_x, scale_y) = transform.get_scale()
  fn scaled_x(value : Double) -> Double {
    match graph.primitive_units {
      UserSpaceOnUse => value * scale_x
      ObjectBoundingBox => value * target_bounds.width()
    }
  }
  fn scaled_y(value : Double) -> Double {
    match graph.primitive_units {
      UserSpaceOnUse => value * scale_y
      ObjectBoundingBox => value * target_bounds.height()
    }
  }
  fn input_surface(name : String) -> Image {
    match name {
      "SourceGraphic" => source
      "SourceAlpha" => source_alpha
      "" => previous
      "FillPaint" | "StrokePaint" | "BackgroundImage" | "BackgroundAlpha" =>
        match paints.get(name) {
          Some(image) => image
          None => {
            let image = paint_input(name).unwrap_or_else(() => {
              Image::new(source.width, source.height)
            })
            paints[name] = image
            image
          }
        }
      _ =>
        named
        .get(name)
        .unwrap_or_else(() => Image::new(source.width, source.height))
    }
  }
  for i, primitive in graph.primitives {
    let linear_rgb = graph.linear_color.get(i).unwrap_or(true)
    fn referenced_local(name : String) -> BoundingBox {
      match name {
        "" => previous_region
        "SourceGraphic"
        | "SourceAlpha"
        | "FillPaint"
        | "StrokePaint"
        | "BackgroundImage"
        | "BackgroundAlpha" => rect
        _ => named_regions.get(name).unwrap_or(rect)
      }
    }
    let mut input_region : BoundingBox? = None
    for name in primitive.region_inputs() {
      let bounds = referenced_local(name)
      input_region = Some(
        match input_region {
          Some(combined) => combined.union(bounds)
          None => bounds
        },
      )
    }
    let defaults = input_region.unwrap_or(rect)
    let requested_local = match graph.primitive_regions.get(i) {
      Some(Some(region)) =>
        filter_primitive_region(region, graph, target_local, defaults)
      _ => defaults
    }
    let local_region : BoundingBox = {
      min_x: requested_local.min_x.max(rect.min_x),
      min_y: requested_local.min_y.max(rect.min_y),
      max_x: requested_local.max_x.min(rect.max_x),
      max_y: requested_local.max_y.min(rect.max_y),
    }
    let region = raster_transform.apply_bbox(local_region)
    let (output, result_name) = match primitive {
      GraphColorMatrix(input~, result~, matrix~) =>
        (
          apply_filter(input_surface(input), ColorMatrix(matrix), linear_rgb~),
          result,
        )
      GraphGaussianBlur(input~, result~, radius_x~, radius_y~) =>
        (
          blur_filter_image_xy(
            input_surface(input),
            scaled_x(radius_x),
            scaled_y(radius_y),
            linear_rgb,
          ),
          result,
        )
      GraphOffset(input~, result~, dx~, dy~) => {
        let (dx, dy) = match graph.primitive_units {
          ObjectBoundingBox =>
            (dx * target_local.width(), dy * target_local.height())
          UserSpaceOnUse => (dx, dy)
        }
        let (from_x, from_y) = transform.apply(0.0, 0.0)
        let (to_x, to_y) = transform.apply(dx, dy)
        (
          offset_filter_image(
            input_surface(input),
            to_x - from_x,
            to_y - from_y,
          ),
          result,
        )
      }
      GraphBlend(input~, input2~, result~, mode~) =>
        (
          blend_images(
            input_surface(input2),
            input_surface(input),
            mode,
            linear_rgb~,
          ),
          result,
        )
      GraphComposite(input~, input2~, result~, operator~, k1~, k2~, k3~, k4~) =>
        (
          composite_filter_images(
            input_surface(input),
            input_surface(input2),
            operator,
            k1,
            k2,
            k3,
            k4,
            linear_rgb,
          ),
          result,
        )
      GraphFlood(result~, color~) =>
        (Image::filled(source.width, source.height, color), result)
      GraphMerge(result~, inputs~) => {
        let mut merged = Image::new(source.width, source.height)
        for input in inputs {
          merged = blend_images(
            merged,
            input_surface(input),
            Normal,
            linear_rgb~,
          )
        }
        (merged, result)
      }
      GraphComponentTransfer(input~, result~, red~, green~, blue~, alpha~) =>
        (
          component_transfer_filter_image(
            input_surface(input),
            red,
            green,
            blue,
            alpha,
            linear_rgb,
          ),
          result,
        )
      GraphMorphology(input~, result~, radius_x~, radius_y~, operator~) =>
        (
          morphology_filter_image(
            input_surface(input),
            scaled_x(radius_x),
            scaled_y(radius_y),
            operator,
            linear_rgb,
          ),
          result,
        )
      GraphConvolveMatrix(
        input~,
        result~,
        order_x~,
        order_y~,
        kernel~,
        divisor~,
        bias~,
        target_x~,
        target_y~,
        edge_mode~,
        preserve_alpha~,
      ) =>
        (
          convolve_filter_image(
            input_surface(input),
            order_x,
            order_y,
            kernel,
            divisor,
            bias,
            target_x,
            target_y,
            edge_mode,
            preserve_alpha,
            linear_rgb,
          ),
          result,
        )
      GraphDisplacementMap(
        input~,
        input2~,
        result~,
        scale~,
        x_channel~,
        y_channel~,
      ) => {
        let scale_x = filter_primitive_x(graph, scale, target_local)
        let scale_y = filter_primitive_y(graph, scale, target_local)
        let displacement_transform = {
          ..transform.multiply(Transform::scale(scale_x, scale_y)),
          e: 0.0,
          f: 0.0,
        }
        (
          displacement_filter_image(
            input_surface(input),
            input_surface(input2),
            displacement_transform,
            x_channel,
            y_channel,
            linear_rgb,
          ),
          result,
        )
      }
      GraphTurbulence(
        result~,
        base_x~,
        base_y~,
        octaves~,
        seed~,
        stitch~,
        fractal_noise~,
      ) => {
        let frequency_x = match graph.primitive_units {
          ObjectBoundingBox =>
            if target_bounds.width() <= 0.0 {
              0.0
            } else {
              base_x / target_bounds.width()
            }
          UserSpaceOnUse => base_x
        }
        let frequency_y = match graph.primitive_units {
          ObjectBoundingBox =>
            if target_bounds.height() <= 0.0 {
              0.0
            } else {
              base_y / target_bounds.height()
            }
          UserSpaceOnUse => base_y
        }
        (
          turbulence_filter_image(
            source.width,
            source.height,
            frequency_x,
            frequency_y,
            octaves,
            seed,
            stitch,
            fractal_noise,
            region,
            origin_x,
            origin_y,
            linear_rgb,
          ),
          result,
        )
      }
      GraphTile(input~, result~) =>
        (
          tile_filter_image(
            input_surface(input),
            raster_transform.apply_bbox(referenced_local(input)),
          ),
          result,
        )
      GraphImage(result~, href~, aspect~) => {
        let image = if href.has_prefix("#") {
          local_image(href[1:].to_owned())
        } else {
          filter_image_resource(
            source.width,
            source.height,
            href,
            raster_transform.apply_bbox(requested_local),
            aspect,
            image_resolver,
          )
        }
        match image {
          Some(image) => (image, result)
          None => {
            diagnostics.push({
              kind: ResourceUnresolved,
              stage: Image,
              resource: href,
              node_id: graph.id,
            })
            (Image::new(source.width, source.height), result)
          }
        }
      }
      GraphDiffuseLighting(
        input~,
        result~,
        surface_scale~,
        diffuse_constant~,
        color~,
        light~,
      ) =>
        (
          lighting_filter_image(
            input_surface(input),
            filter_primitive_y(graph, surface_scale, target_bounds),
            diffuse_constant,
            1.0,
            color,
            resolve_filter_light(
              graph, light, target_bounds, origin_x, origin_y,
            ),
            false,
            linear_rgb,
          ),
          result,
        )
      GraphSpecularLighting(
        input~,
        result~,
        surface_scale~,
        specular_constant~,
        specular_exponent~,
        color~,
        light~,
      ) =>
        (
          lighting_filter_image(
            input_surface(input),
            filter_primitive_y(graph, surface_scale, target_bounds),
            specular_constant,
            specular_exponent,
            color,
            resolve_filter_light(
              graph, light, target_bounds, origin_x, origin_y,
            ),
            true,
            linear_rgb,
          ),
          result,
        )
    }
    // A pass-through or alpha-preserving color adjustment keeps the input's
    // clipped edges. Multiplying by the same coverage again darkens them.
    let preserves_coverage = match primitive {
      GraphOffset(input~, dx=0.0, dy=0.0, ..)
      | GraphGaussianBlur(input~, radius_x=0.0, radius_y=0.0, ..)
      | GraphComponentTransfer(input~, alpha=TransferIdentity, ..) =>
        Some(input)
      GraphColorMatrix(input~, matrix~, ..) if matrix[15] == 0.0 &&
        matrix[16] == 0.0 &&
        matrix[17] == 0.0 &&
        matrix[18] == 1.0 &&
        matrix[19] == 0.0 => Some(input)
      _ => None
    }
    let reuses_clip = match preserves_coverage {
      Some(input) if (input == "" && i > 0) || named_regions.contains(input) => {
        let bounds = referenced_local(input)
        local_region.min_x <= bounds.min_x &&
        local_region.min_y <= bounds.min_y &&
        local_region.max_x >= bounds.max_x &&
        local_region.max_y >= bounds.max_y
      }
      _ => false
    }
    let clipped = if local_region.width() <= 0.0 || local_region.height() <= 0.0 {
      Image::new(output.width, output.height)
    } else if affine_clip && !reuses_clip {
      clip_affine_filter(output, local_region, raster_transform)
    } else if region.min_x > 0.0 ||
      region.min_y > 0.0 ||
      region.max_x < output.width.to_double() ||
      region.max_y < output.height.to_double() {
      clip_filter_result(output.clone(), region)
    } else {
      output
    }
    previous = clipped
    previous_region = local_region
    match result_name {
      ""
      | "SourceGraphic"
      | "SourceAlpha"
      | "FillPaint"
      | "StrokePaint"
      | "BackgroundImage"
      | "BackgroundAlpha" => ()
      _ => {
        named.set(result_name, clipped)
        named_regions.set(result_name, local_region)
      }
    }
  }
  previous
}
