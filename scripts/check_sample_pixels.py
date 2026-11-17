"""Independently inspect the sample collection and compare original renders.

Pass a Krita executable to also open each reference-result ORA in Krita.
"""
from pathlib import Path
import io
import json
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops
from prepare_artwork import krita_export

ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / "web/assets/sample-catalog.json").read_text(encoding="utf-8"))
reports = json.loads((ROOT / "fixtures/sample-validation.json").read_text(encoding="utf-8"))


def maximum_error(a, b):
    assert a.size == b.size
    return max(pair[1] for pair in ImageChops.difference(a.convert("RGBA"), b.convert("RGBA")).getextrema())


for sample in catalog["samples"]:
    reference = ROOT / ("fixtures/capitole-krita.png" if sample["id"] == "capitole" else f"fixtures/samples/{sample['id']}-krita.png")
    with zipfile.ZipFile(ROOT / "web" / sample["file"]) as archive:
        root = ET.fromstring(archive.read("stack.xml"))
        assert len(list(root.iter("layer"))) == sample["layerCount"]
        original = Image.open(io.BytesIO(archive.read("mergedimage.png"))).convert("RGBA")
        error = maximum_error(original, Image.open(reference))
        assert error <= 2, (sample["id"], error)
        for layer in root.iter("layer"):
            Image.open(io.BytesIO(archive.read(layer.get("src")))).verify()
    with zipfile.ZipFile(ROOT / "web" / sample["practice"]["file"]) as archive:
        assert archive.infolist()[0].filename == "mimetype"
        assert archive.infolist()[0].compress_type == zipfile.ZIP_STORED
        start = Image.open(io.BytesIO(archive.read("mergedimage.png")))
        assert maximum_error(start, Image.open(ROOT / "web" / sample["practice"]["start"])) == 0
        assert len(list(ET.fromstring(archive.read("stack.xml")).iter("layer"))) == sample["layerCount"]
    if sample["id"] != "capitole":
        report = next(r for r in reports if r["id"] == sample["id"])
        assert report["web_ora_krita_max_error"] == error
        assert report["original_kra_ora_max_error"] <= 2
    if len(sys.argv) > 1:
        with tempfile.TemporaryDirectory(prefix="moonora-practice-goal-") as folder:
            output = Path(folder) / "goal.png"
            krita_export(Path(sys.argv[1]).resolve(), ROOT / "web" / sample["practice"]["goalFile"], output)
            goal_error = maximum_error(Image.open(output), Image.open(ROOT / "web" / sample["practice"]["goal"]))
            assert goal_error <= 2, (sample["id"], "goal", goal_error)
            print(sample["id"], "reference-result ORA reopened in Krita; maximum error", goal_error)
    print("PASS:", sample["id"], "source layers, practice file and independent Krita render; maximum error", error)
