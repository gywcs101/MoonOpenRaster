///|
fn main raise {
  let image = @ora.Image::new(1, 1, [255, 0, 0, 255])
  let node = @ora.Node::Layer(@ora.Properties::new("Red"), image)
  let document = @ora.Document::new(1, 1, [node])
  let encoded = document.write()
  let decoded = @ora.read(encoded)
  println(decoded.render().pixels().length())
}
