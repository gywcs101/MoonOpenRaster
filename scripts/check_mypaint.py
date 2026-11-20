"""Independent MyPaint ORA vector-layer round trip using the portable Windows build."""
import argparse
from io import BytesIO
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image
from check_rgba16 import decode_rgba, png


ROOT = Path(__file__).resolve().parents[1]
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="5" height="3"><path fill="red" d="M0 0H5V3H0Z"/></svg>'
RGBA16 = (10001, 20002, 30003, 65535)
MYPAINT_SCRIPT = """
import sys
from lib.document import Document
from lib.mypaintlib import CombineNormal

doc = Document()
try:
    doc.load(sys.argv[1])
    assert type(doc.layer_stack[0]).__name__ == 'VectorLayer'
    doc.update_frame(x=0, y=0, width=16, height=8)
    doc.set_frame_enabled(True)
    doc.layer_stack.mode = CombineNormal
    for layer in doc.layer_stack:
        layer.mode = CombineNormal
    doc.save(sys.argv[2])
    doc.layer_stack.save_as_png(sys.argv[3], 0, 0, 16, 8, alpha=True, render_background=False)
finally:
    doc.cleanup()
"""


def write_seed(path):
    preview = png(16, 8, 8, lambda x, y: (0, 0, 0, 255))
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image w="16" h="8" version="0.0.6"><stack><layer name="Vector" src="data/shape.svg" x="1" y="1"/><layer name="Raster" src="data/base.png"/></stack></image>')
        archive.writestr("data/shape.svg", SVG)
        archive.writestr("data/base.png", png(16, 8, 16, lambda x, y: RGBA16))
        archive.writestr("mergedimage.png", preview)
        archive.writestr("Thumbnails/thumbnail.png", preview)


def verify_vector(archive, expected_x):
    layer = ET.fromstring(archive.read("stack.xml")).find("./stack/layer[@name='Vector']")
    assert layer.get("x") == str(expected_x) and layer.get("y") == "1"
    assert archive.read(layer.get("src")) == SVG


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mypaint", type=Path, help="Root folder of the extracted MyPaint standalone archive")
    args = parser.parse_args()
    runtime = (args.mypaint / "mingw64").resolve(strict=True)
    env = dict(os.environ, PATH=str(runtime / "bin") + os.pathsep + os.environ["PATH"],
               PYTHONPATH=str(runtime / "lib/mypaint"))

    def mypaint(source, archive, png_output):
        subprocess.run([str(runtime / "bin/python.exe"), "-c", MYPAINT_SCRIPT,
                        str(source), str(archive), str(png_output)],
                       env=env, check=True, timeout=40)

    subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
    cli = ROOT / "_build/js/debug/build/cmd/main/main.js"
    with tempfile.TemporaryDirectory(prefix="moonora-mypaint-") as temporary:
        work = Path(temporary)
        seed = work / "seed.ora"
        write_seed(seed)
        source = work / "mypaint-original.ora"
        mypaint(seed, source, work / "mypaint-original.png")
        with zipfile.ZipFile(source) as archive:
            verify_vector(archive, 1)

        changes = work / "edits.json"
        changes.write_text('[{"path":[0],"x":8}]', encoding="utf-8")
        for name, input_file in (("mypaint-original", source), ("mixed-16-bit", seed)):
            edited = work / f"{name}-edited.ora"
            reopened = work / f"{name}-reopened.ora"
            reference = work / f"{name}-reference.png"
            subprocess.run(["node", str(cli), "edit", str(input_file), str(edited), str(changes)], check=True)
            mypaint(edited, reopened, reference)
            with zipfile.ZipFile(reopened) as archive:
                verify_vector(archive, 8)
            with zipfile.ZipFile(edited) as archive, Image.open(reference) as ref:
                verify_vector(archive, 8)
                preview_bytes = archive.read("mergedimage.png")
                preview = Image.open(BytesIO(preview_bytes)).convert("RGBA")
                ref_rgba = ref.convert("RGBA")
                assert preview.size == (16, 8)
                assert ref_rgba.width >= 16 and ref_rgba.height >= 8
                # MyPaint's tile-based PNG export can extend the output past the ORA frame.
                ref_rgba = ref_rgba.crop((0, 0, 16, 8))
                assert preview.getpixel((1, 1)) != (255, 0, 0, 255)
                assert ref_rgba.getpixel((8, 1)) == (255, 0, 0, 255)
                if name == "mixed-16-bit":
                    raster = ET.fromstring(archive.read("stack.xml")).find("./stack/layer[@name='Raster']")
                    assert decode_rgba(archive.read(raster.get("src"))) == (16, 8, 16, [RGBA16] * 128)
                    assert decode_rgba(preview_bytes)[2] == 16
                difference = max(abs(a - b) for a, b in zip(preview.tobytes(), ref_rgba.tobytes()))
                assert difference <= 1, (name, difference)
            print(f"PASS {name}: MyPaint reopens and retains SVG; maximum channel difference {difference}")


if __name__ == "__main__":
    main()
