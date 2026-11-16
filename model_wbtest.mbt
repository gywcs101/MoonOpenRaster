///|
test "image owns input and output buffers" {
  let pixels : Array[Byte] = [255, 0, 0, 255]
  let image = Image::new(1, 1, pixels)
  pixels[0] = 0
  let result = image.pixels()
  assert_eq(result[0], 255)
  result[0] = 0
  assert_eq(image.pixels()[0], 255)
}
