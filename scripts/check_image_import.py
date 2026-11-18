"""Generate original test inputs and exercise standalone image import through MoonBit."""
from io import BytesIO
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image, ImageChops, ImageStat
from check_rgba16 import decode_rgba

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "_build/image-import"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGBA", (16, 12), (41, 99, 173, 255))
    image.paste((23, 54, 117, 128), (2, 2, 10, 8))
    image.save(OUT / "layer.png")
    image.save(OUT / "layer.webp", lossless=True)
    image.convert("RGB").save(OUT / "lossy.webp")
    image.convert("RGB").save(OUT / "layer.bmp")
    image.resize((16, 16)).save(OUT / "layer.ico", sizes=[(16, 16)])
    exif = Image.Exif()
    exif[274] = 6
    image.convert("RGB").save(OUT / "oriented.jpg", progressive=True, exif=exif)
    image.convert("RGB").resize((24, 24)).save(OUT / "progressive-edge.jpg", progressive=True, subsampling=2)
    first = Image.new("RGB", (16, 12), (39, 107, 143))
    second = Image.new("RGB", (16, 12), (157, 9, 37))
    first.save(OUT / "animated.gif", save_all=True, append_images=[second], duration=100)
    first.save(OUT / "animated.webp", save_all=True, append_images=[second], duration=100)
    gray = Image.new("I;16", (16, 12), 10001)
    gray.save(OUT / "multi.tiff", save_all=True, append_images=[Image.new("I;16", (16, 12), 46783)])
    subprocess.run(["node", "scripts/check_image_import.mjs"], cwd=ROOT, check=True)
    assert decode_rgba((OUT / "multi.tiff.png").read_bytes()) == (16, 12, 16, [(10001, 10001, 10001, 65535)] * 192)
    with Image.open(OUT / "layer.webp.png") as alpha:
        assert alpha.getpixel((3, 3)) == (23, 54, 117, 128)
    with Image.open(OUT / "animated.gif.png") as frame:
        assert frame.getpixel((0, 0)) == (39, 107, 143, 255)
    # Independently check the larger reference photo used in the actual gallery.
    gallery = ROOT / "web/assets/import-samples"
    with zipfile.ZipFile(gallery / "postcard-goal.ora") as result:
        tree = ET.fromstring(result.read("stack.xml"))
        layer = next(child for child in tree.iter("layer") if child.get("name") == "照片窗口")
        decoded = Image.open(BytesIO(result.read(layer.get("src")))).convert("RGB")
    with Image.open(gallery / "tide.jpg") as source:
        delta = ImageStat.Stat(ImageChops.difference(source.convert("RGB"), decoded))
        assert max(delta.mean) < 1 and max(channel[1] for channel in delta.extrema) < 48, delta.extrema
    print("PASS: independent TIFF low bits, WebP transparency and GIF first-frame pixels")


if __name__ == "__main__":
    main()
