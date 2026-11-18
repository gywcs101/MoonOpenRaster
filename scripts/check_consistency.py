"""Apply one fixed edit through a package consumer, CLI and web bridge."""
from pathlib import Path
from io import BytesIO
import argparse, json, subprocess, tempfile, zipfile, xml.etree.ElementTree as ET
from check_rgba16 import verify_saved
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
parser = argparse.ArgumentParser()
parser.add_argument("--rgba16", action="store_true")
wide = parser.parse_args().rgba16
fixture = ROOT / "fixtures" / ("gradient16.ora" if wide else "krita-5.3.4.ora")
out = ROOT / "_build" / ("consistency16" if wide else "consistency")
out.mkdir(parents=True, exist_ok=True)
edit = {"path":[0,0],"name":"接口一致性 · 中文","x":-3,"y":7,"opacity":0.5,"visible":True,"composite_op":"svg:multiply"}
if wide:
    edit = {"path": [0, 0], "name": "Light", "x": 9, "y": 6, "opacity": 0.5, "visible": True, "composite_op": "svg:src-over"}
(out / "edits.json").write_text(json.dumps([edit], ensure_ascii=False), encoding="utf-8")
# Workspaces are separate from the main checkout; only public APIs are used.
with tempfile.TemporaryDirectory(prefix="moonora-parity-") as directory:
    work = Path(directory)
    (work / "moon.work").write_text('members = [' + json.dumps(str(ROOT).replace("\\", "/")) + ', "consumer"]\n', encoding="utf-8")
    consumer = work / "consumer"
    consumer.mkdir()
    (consumer / "moon.mod").write_text('name = "local/parity"\nimport { "gywcs101/MoonOpenRaster@0.2.0", "moonbitlang/x@0.5.7" }\n')
    (consumer / "moon.pkg").write_text('import { "gywcs101/MoonOpenRaster" @ora, "moonbitlang/x/fs", "moonbitlang/core/env" }\noptions("is-main":true)\n')
    (consumer / "main.mbt").write_text(f'''fn main raise {{
      let args=@env.args()
      let doc=@ora.read(@fs.read_file_to_bytes(args[2]))
      let edited=doc.set_properties([0,0],@ora.Properties::new({json.dumps(edit["name"], ensure_ascii=False)},x={edit["x"]},y={edit["y"]},opacity=0.5,visible=true,composite_op={json.dumps(edit["composite_op"])}))
      assert_eq(edited.bit_depth(), {16 if wide else 8})
      @fs.write_bytes_to_file(args[3],edited.write())
    }}''', encoding="utf-8")
    subprocess.run(["moon","run",".","--target","js","--",str(fixture),str(out / "library.ora")],cwd=consumer,check=True)
cli = ROOT / "_build/js/debug/build/cmd/main/main.js"
for name in ["cli.ora", "edited.png"]:
    (out / name).unlink(missing_ok=True)
subprocess.run(["node",str(cli),"edit",str(fixture),str(out / "cli.ora"),str(out / "edits.json")],check=True)
bridge = ROOT / "_build/js/debug/build/bridge/bridge.js"
script = '''import fs from 'node:fs'; import {request} from %s;
const run=q=>{const r=JSON.parse(request(JSON.stringify(q)));if(!r.ok)throw Error(r.error);return r;};
run({action:'open',data:fs.readFileSync(process.argv[1]).toString('base64')});
const edit=JSON.parse(fs.readFileSync(process.argv[3],'utf8'))[0];
run({action:'edit', ...edit, op:edit.composite_op});
fs.writeFileSync(process.argv[2],Buffer.from(run({action:'export'}).data,'base64'));
''' % json.dumps(bridge.as_uri())
subprocess.run(["node","--input-type=module","-e",script,str(fixture),str(out / "bridge.ora"),str(out / "edits.json")],check=True)
pixels, trees = [], []
for name in ["library", "cli", "bridge"]:
    archive = out / (name + ".ora")
    if wide:
        verify_saved(archive)
    with zipfile.ZipFile(archive) as z:
        png = z.read("mergedimage.png")
        pixels.append(Image.open(BytesIO(png)).convert("RGBA").tobytes())
        trees.append(ET.tostring(ET.fromstring(z.read("stack.xml"))))
        if name == "library": (out / "edited.png").write_bytes(png)
assert pixels[0] == pixels[1] == pixels[2]
assert trees[0] == trees[1] == trees[2]
print("PASS: external library, CLI and web bridge produce identical edited tree and pixels; browser reference ready")
