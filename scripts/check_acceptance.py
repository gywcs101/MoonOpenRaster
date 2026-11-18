"""Independent regressions for resource naming, validation and randomized round trips."""
from pathlib import Path
from io import BytesIO
import json, random, subprocess, tempfile, zipfile, xml.etree.ElementTree as ET
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"

def png(image):
    stream = BytesIO()
    image.save(stream, "PNG")
    return stream.getvalue()

def archive(path, xml, resources):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "image/openraster", compress_type=zipfile.ZIP_STORED)
        z.writestr("stack.xml", xml)
        z.writestr("mergedimage.png", png(Image.new("RGBA", (2, 2))))
        for name, data in resources.items():
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)

def cli(*args, success=True):
    result = subprocess.run(["node", str(CLI), *map(str, args)], cwd=ROOT, capture_output=True)
    assert (result.returncode == 0) == success, result.stderr.decode(errors="replace")
    return result

with tempfile.TemporaryDirectory(prefix="moonora-regression-") as directory:
    work = Path(directory)
    one = png(Image.new("RGBA", (1, 1), (255, 0, 0, 255)))
    source, edits, output = work / "input.ora", work / "edits.json", work / "output.ora"
    archive(source, '<image w="2" h="2"><stack><layer name="Keep" x="1" src="data/a.png"/></stack></image>', {"data/a.png": one})
    for entry in [{"x": 1.5}, {"y": -0.2}, {"x": 1e30}, {"x": "2"}, {"y": None}, {"visible": "false"}, {"opacity": "0.5"}, {"name": 12}, {"composite_op": False}, {"path": [0.1]}, {"path": [True]}]:
        edits.write_text(json.dumps([{"path": [0], **entry}]), encoding="utf-8")
        cli("edit", source, output, edits, success=False)
        assert not output.exists(), entry
    # Partial CLI edits retain unspecified properties.
    edits.write_text('[{"path":[0],"y":1}]')
    cli("edit", source, output, edits)
    with zipfile.ZipFile(output) as z:
        layer = ET.fromstring(z.read("stack.xml")).find(".//layer")
        assert layer.get("name") == "Keep" and layer.get("x") == "1" and layer.get("y") == "1"
    output.unlink()
    for key, value in [("w", "2.8"), ("h", "1e2"), ("w", "999999999999999999999"), ("w", "0"), ("w", "16385"), ("h", "-1")]:
        attrs = {"w": "2", "h": "2", key: value}
        xml = '<image ' + ' '.join(f'{k}="{v}"' for k,v in attrs.items()) + '><stack/></image>'
        archive(source, xml, {})
        cli("inspect", source, success=False)
        cli("render", source, output, success=False)
        assert not output.exists()
    for key, value in [("x", "0.6"), ("y", "1e2"), ("x", "1000001"), ("visibility", "maybe"), ("opacity", "1.1")]:
        archive(source, f'<image w="2" h="2"><stack><layer src="data/a.png" {key}="{value}"/></stack></image>', {"data/a.png": one})
        cli("render", source, output, success=False)
        assert not output.exists()
    archive(source, '<image w="2" h="2"><stack><stack isolation="typo"/></stack></image>', {})
    cli("render", source, output, success=False)
    rng = random.Random(20261118)
    for case in range(24):
        width, height = rng.randint(1, 6), rng.randint(1, 6)
        image = ET.Element("image", {"w": str(width), "h": str(height), "custom-image": "yes"})
        stack = ET.SubElement(image, "stack", {"name": "ignored", "opacity": "0.5", "x": "12", "isolation": "auto", "custom-root": "retained"})
        parent = stack
        for depth in range(case % 5):
            parent = ET.SubElement(parent, "stack", {"name": f"嵌套{depth}", "isolation": "isolate", "x": "99", "custom-group": "yes"})
        resources = {}
        paints = []
        for index in range(rng.randint(1, 8)):
            layer = Image.new("RGBA", (rng.randint(1, 5), rng.randint(1, 5)), tuple(rng.randint(0,255) for _ in range(3)) + (255,))
            x, y, visible = rng.randint(-4, 4), rng.randint(-4, 4), rng.choice([True, False])
            name = f"data/original-{index}.png"
            ET.SubElement(parent, "layer", {"name": f"中文<{index}>", "src": name, "x": str(x), "y": str(y), "visibility": "visible" if visible else "hidden", "custom-layer": "retained"})
            resources[name] = png(layer)
            paints.append((layer, x, y, visible))
        # Occupy consecutive generated names, including the old first-layer name.
        for serial in range(1, 20):
            resources[f"data/moonopenraster-layer{serial}.png"] = b"extension bytes " + str(serial).encode()
        expected = Image.new("RGBA", (width, height))
        for layer, x, y, visible in reversed(paints):
            if visible: expected.alpha_composite(layer, (x, y))
        archive(source, ET.tostring(image), resources)
        edits.write_text("[]")
        cli("edit", source, output, edits)
        with zipfile.ZipFile(output) as z:
            assert len(z.namelist()) == len(set(z.namelist()))
            assert z.infolist()[0].filename == "mimetype" and z.infolist()[0].compress_type == 0
            tree = ET.fromstring(z.read("stack.xml"))
            assert tree.get("custom-image") == "yes"
            assert tree.find("stack").attrib == {"custom-root": "retained"}
            assert all("x" not in group.attrib and "y" not in group.attrib for group in tree.iter("stack"))
            assert Image.open(BytesIO(z.read("mergedimage.png"))).convert("RGBA").tobytes() == expected.tobytes(), case
            for name, data in resources.items():
                if "moonopenraster" in name: assert z.read(name) == data
        rendered = work / "roundtrip.png"
        cli("render", output, rendered)
        assert Image.open(rendered).convert("RGBA").tobytes() == expected.tobytes()
        output.unlink()
        rendered.unlink()
print("PASS: strict CLI/XML inputs, partial edits, 24 seeded nested-tree Pillow oracles, unique resources and canonical stacks")
