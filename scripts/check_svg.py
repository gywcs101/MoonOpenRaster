"""Check vector-layer preservation and independent SVG + RGBA16 composition."""
import argparse
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile

from check_rgba16 import decode_rgba, png

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "_build/svg-roundtrip"
ATLAS = ROOT / "web/assets/import-samples"
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="1" height="2" fill="#ff0000"/></svg>'
BASE = (10001, 20002, 30003, 65535)


def check_atlas(path):
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read("stack.xml"))
        layer = next(n for n in root.iter("layer") if n.get("name") == "contours")
        assert (layer.get("x"), layer.get("y")) == ("30", "58")
        assert layer.get("src").endswith(".svg")
        assert archive.read(layer.get("src")) == (ATLAS / "contours.svg").read_bytes()
        terrain = next(n for n in root.iter("layer") if n.get("name") == "高程窗口")
        assert decode_rgba(archive.read(terrain.get("src")))[2] == 16
        assert archive.read("mergedimage.png") == (ATLAS / "atlas-goal.png").read_bytes()
    print("PASS: atlas retains exact SVG and 16-bit terrain after saving")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser-output", type=Path)
    args = parser.parse_args()
    if args.browser_output:
        check_atlas(args.browser_output)
        return

    OUT.mkdir(parents=True, exist_ok=True)
    source, edited, output = (OUT / name for name in ("input.ora", "edited.ora", "rendered.png"))
    for dest in (edited, output):
        dest.unlink(missing_ok=True)
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="4" h="2"><stack><stack name="Group"><layer name="Vector" src="data/vector.svg"/></stack><layer name="Base" src="data/base.png"/></stack></image>')
        archive.writestr("data/vector.svg", SVG)
        archive.writestr("data/base.png", png(4, 2, 16, lambda x, y: BASE))
        archive.writestr("mergedimage.png", png(4, 2, 16, lambda x, y: BASE))
        archive.writestr("Thumbnails/thumbnail.png", png(4, 2, 8, lambda x, y: (39, 78, 117, 255)))
    changes = OUT / "edits.json"
    changes.write_text(json.dumps([{"path": [0, 0], "x": 2, "opacity": .5}]), encoding="utf-8")
    subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
    cli = ROOT / "_build/js/debug/build/cmd/main/main.js"
    subprocess.run(["node", str(cli), "edit", str(source), str(edited), str(changes)], check=True)
    subprocess.run(["node", str(cli), "render", str(edited), str(output)], check=True)
    # The isolated group stores round(0.5 * 65535) before it blends onto Base.
    a = 32768
    blend = tuple((front * a + back * (65535 - a) + 32767) // 65535
                  for front, back in zip((65535, 0, 0, 65535), BASE))
    with zipfile.ZipFile(edited) as archive:
        layer = ET.fromstring(archive.read("stack.xml")).find("./stack/stack/layer")
        assert layer.get("x") == "2"
        assert float(layer.get("opacity")) == .5
        assert layer.get("src").endswith(".svg") and archive.read(layer.get("src")) == SVG
        assert decode_rgba(archive.read("mergedimage.png")) == (4, 2, 16, [BASE, BASE, blend, BASE] * 2)
        assert archive.read("mergedimage.png") == output.read_bytes()
        assert archive.read("Thumbnails/thumbnail.png")[24] == 8
    check_atlas(ATLAS / "atlas-goal.ora")
    print("PASS: CLI edits a nested SVG layer, recomposes precise RGBA16, and preserves the vector source")


if __name__ == "__main__":
    main()
