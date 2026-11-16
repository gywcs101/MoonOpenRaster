///|
pub(all) suberror OraError {
  InvalidDocument(String)
  Unsupported(String)
}

///|
pub struct Image {
  width : Int32
  height : Int32
  pixels : Array[Byte]
}

///|
pub fn Image::new(
  width : Int32,
  height : Int32,
  pixels : Array[Byte],
) -> Image raise OraError {
  if width <= 0 ||
    height <= 0 ||
    width > 16384 ||
    height > 16384 ||
    width.to_int64() * height.to_int64() > 16777216 {
    raise InvalidDocument("Image dimensions exceed limits")
  }
  if pixels.length() != width * height * 4 {
    raise InvalidDocument("RGBA length mismatch")
  }
  { width, height, pixels: pixels.copy(), }
}

///|
pub fn Image::width(self : Image) -> Int32 {
  self.width
}

///|
pub fn Image::height(self : Image) -> Int32 {
  self.height
}

///|
pub fn Image::pixels(self : Image) -> Array[Byte] {
  self.pixels.copy()
}

///|
pub(all) enum Isolation {
  Auto
  Isolate
}

///|
pub struct Properties {
  name : String
  x : Int32
  y : Int32
  visible : Bool
  opacity : Double
  composite_op : String
}

///|
pub fn Properties::new(
  name : String,
  x~ : Int32 = 0,
  y~ : Int32 = 0,
  visible~ : Bool = true,
  opacity~ : Double = 1.0,
  composite_op~ : String = "svg:src-over",
) -> Properties raise OraError {
  if opacity.is_nan() || opacity < 0.0 || opacity > 1.0 {
    raise InvalidDocument("Opacity must be between zero and one")
  }
  if x < -1000000 || x > 1000000 || y < -1000000 || y > 1000000 {
    raise InvalidDocument("Offset exceeds limits")
  }
  { name, x, y, visible, opacity, composite_op, }
}

///|
pub(all) enum Node {
  Layer(Properties, Image)
  Group(Properties, Isolation, Array[Node])
}

///|
pub struct Document {
  width : Int32
  height : Int32
  name : String
  children : Array[Node]
}

///|
pub fn Document::new(
  width : Int32,
  height : Int32,
  children : Array[Node],
  name~ : String = "Untitled",
) -> Document raise OraError {
  if width <= 0 ||
    height <= 0 ||
    width > 16384 ||
    height > 16384 ||
    width.to_int64() * height.to_int64() > 16777216 {
    raise InvalidDocument("Canvas dimensions exceed limits")
  }
  { width, height, name, children: children.copy(), }
}

///|
pub fn Document::width(self : Document) -> Int32 {
  self.width
}

///|
pub fn Document::height(self : Document) -> Int32 {
  self.height
}

///|
pub fn Document::name(self : Document) -> String {
  self.name
}

///|
pub fn Document::children(self : Document) -> Array[Node] {
  self.children.copy()
}
