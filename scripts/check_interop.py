"""Independent Python ZIP/XML and Pillow reference for the JavaScript CLI."""
from pathlib import Path
from io import BytesIO
from unittest.mock import patch
import subprocess, tempfile, zipfile, json, xml.etree.ElementTree as ET
from PIL import Image
ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js"], cwd=ROOT, check=True)
cli = ROOT / "_build/js/debug/build/cmd/main/main.js"
def png(image):
    stream = BytesIO()
    image.save(stream, "PNG")
    return stream.getvalue()
with tempfile.TemporaryDirectory(prefix="moonora-interop-") as folder:
    p = Path(folder)
    background = Image.new("RGBA", (4, 4), (0, 0, 255, 255))
    foreground = Image.new("RGBA", (2, 2), (255, 0, 0, 128))
    expected = background.copy()
    expected.alpha_composite(foreground, (1, 1))
    xml = b'<image w="4" h="4" name="Independent" xres="96"><stack><stack name="Group" isolation="isolate"><layer name="Red" src="data/red.png" x="1" y="1" custom="preserve"/></stack><layer name="Blue" src="data/blue.png"/></stack></image>'
    with zipfile.ZipFile(p / "input.ora", "w") as z:
        z.writestr("mimetype", "image/openraster", compress_type=zipfile.ZIP_STORED)
        for name, data in [("stack.xml", xml), ("data/red.png", png(foreground)), ("data/blue.png", png(background)), ("mergedimage.png", png(expected)), ("Thumbnails/thumbnail.png", png(expected)), ("notes.txt", b"preserved extension")]:
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    subprocess.run(["node", str(cli), "render", str(p / "input.ora"), str(p / "result.png")], check=True, cwd=ROOT)
    assert Image.open(p / "result.png").convert("RGBA").tobytes() == expected.tobytes()
    (p / "edits.json").write_text('[]')
    subprocess.run(["node", str(cli), "edit", str(p / "input.ora"), str(p / "output.ora"), str(p / "edits.json")], check=True, cwd=ROOT)
    with zipfile.ZipFile(p / "output.ora") as z:
        assert z.infolist()[0].filename == "mimetype"
        assert z.infolist()[0].compress_type == 0
        assert z.read("notes.txt") == b"preserved extension"
        tree = ET.fromstring(z.read("stack.xml"))
        assert (tree.attrib["xres"], tree.attrib["yres"]) == ("96", "72")
        assert tree.find(".//layer").attrib["custom"] == "preserve"
        assert Image.open(BytesIO(z.read("mergedimage.png"))).convert("RGBA").tobytes() == expected.tobytes()
        assert Image.open(BytesIO(z.read("Thumbnails/thumbnail.png"))).size == (4, 4)
    # Lower Python's size threshold to exercise ZIP64 metadata without a huge file.
    with zipfile.ZipFile(p / "input.ora") as regular, patch.object(zipfile, "ZIP64_LIMIT", 32):
        with zipfile.ZipFile(p / "zip64.ora", "w") as wide:
            for entry in regular.infolist():
                wide.writestr(entry.filename, regular.read(entry), compress_type=entry.compress_type)
    assert b"PK\x06\x06" in (p / "zip64.ora").read_bytes()
    subprocess.run(["node", str(cli), "render", str(p / "zip64.ora"), str(p / "zip64.png")], check=True)
    with Image.open(p / "zip64.png") as result:
        assert result.convert("RGBA").tobytes() == expected.tobytes()
    # A vector layer can be inspected and preserved in browser view mode.
    import base64
    with zipfile.ZipFile(p / "vector.ora", "w") as z:
        z.writestr("mimetype", "image/openraster")
        z.writestr("stack.xml", '<image w="4" h="4"><stack><layer name="Vector" src="data/vector.svg"/></stack></image>')
        z.writestr("data/vector.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><text>unsupported layer feature</text></svg>')
        z.writestr("mergedimage.png", png(expected))
    encoded = base64.b64encode((p / "vector.ora").read_bytes()).decode()
    bridge = ROOT / "_build/js/debug/build/bridge/bridge.js"
    script = """import {request} from %s;
const data=process.argv[1];const run=q=>JSON.parse(request(JSON.stringify(q)));
const view=run({action:'open',data});
if(!view.ok || view.editable!==false || view.tree[0].name!=='Vector')throw Error('view mode failed');
if(run({action:'export'}).data!==data)throw Error('original bytes changed');
""" % json.dumps(bridge.as_uri())
    subprocess.run(["node", "--input-type=module", "-e", script, encoded], check=True)
    failed = subprocess.run(["node", str(cli), "render", str(p / "input.ora"), str(p / "result.png")], capture_output=True)
    assert failed.returncode != 0
    assert b"Output exists" in failed.stderr
print("PASS: independent ZIP/XML input, Pillow pixel comparison, extension preservation, ZIP order, previews and overwrite protection")
