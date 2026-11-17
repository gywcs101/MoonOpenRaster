"""Check real source-layer artwork against an independently rendered Krita PNG.

Optionally pass Krita's executable to repeat an edited-document reopen locally.
"""
from pathlib import Path
import io
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js"], cwd=ROOT, check=True)
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"


def run(*args):
    subprocess.run(["node", str(CLI), *map(str, args)], cwd=ROOT, check=True)


def compare(a, b, tolerance):
    a, b = a.convert("RGBA"), b.convert("RGBA")
    assert a.size == b.size
    maximum = max(abs(x - y) for x, y in zip(a.tobytes(), b.tobytes()))
    assert maximum <= tolerance, maximum
    return maximum


with tempfile.TemporaryDirectory(prefix="moonora-real-art-") as folder:
    work = Path(folder)
    source = ROOT / "web/assets/capitole.ora"
    report = json.loads((ROOT / "fixtures/artwork-validation.json").read_text(encoding="utf-8"))
    with zipfile.ZipFile(source) as archive:
        assert archive.infolist()[0].filename == "mimetype"
        assert archive.infolist()[0].compress_type == zipfile.ZIP_STORED
        root = ET.fromstring(archive.read("stack.xml"))
        layers = list(root.iter("layer"))
        assert len(layers) == len(report["layers"]) == 7
        assert len(list(root.iter("stack"))) == 2
        assert [layer.get("name") for layer in layers] == [layer["name"] for layer in report["layers"]]
        assert layers[3].get("alpha-preserve") == "true"
        for layer in layers:
            image = Image.open(io.BytesIO(archive.read(layer.get("src"))))
            assert image.mode == "RGBA" and "icc_profile" not in image.info
        merged = Image.open(io.BytesIO(archive.read("mergedimage.png")))
        run("render", source, work / "render.png")
        compare(merged, Image.open(work / "render.png"), 0)
        compare(merged, Image.open(ROOT / "web/assets/capitole-preview.png"), 0)
        error = compare(merged, Image.open(ROOT / "fixtures/capitole-krita.png"), 1)
    extracted = ROOT / "_build/editor-test/layers.zip"
    if extracted.exists():
        with zipfile.ZipFile(extracted) as archive:
            manifest = json.loads(archive.read("layers.json"))
            assert len(manifest) == 7
            assert len({entry["file"] for entry in manifest}) == 7
            for entry in manifest:
                Image.open(io.BytesIO(archive.read(entry["file"]))).verify()
            assert manifest[0]["visible"] is False
            assert manifest[1]["x"] == 127
    # This edit exercises offset, opacity, nested structure and extension retention.
    (work / "edits.json").write_text(json.dumps([{
        "path": [0, 1], "name": "线稿 · 往返验证", "x": 147, "y": 119,
        "opacity": .8, "visible": True, "composite_op": "svg:src-over",
    }], ensure_ascii=False), encoding="utf-8")
    run("edit", source, work / "edited.ora", work / "edits.json")
    run("render", work / "edited.ora", work / "edited.png")
    if len(sys.argv) > 1:
        from prepare_artwork import krita_export
        krita_export(Path(sys.argv[1]).resolve(), work / "edited.ora", work / "reopened.png")
        edited_error = compare(Image.open(work / "edited.png"), Image.open(work / "reopened.png"), 2)
        print("PASS: edited real artwork reopened in Krita; maximum channel error", edited_error)
print("PASS: 7 authentic source layers, group structure, alpha-preserve, fresh previews, layer extraction; Krita channel error", error)
