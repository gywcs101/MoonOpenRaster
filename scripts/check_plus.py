"""W3C plus reference and optional live Krita comparison; no renderer workaround."""
from pathlib import Path
from io import BytesIO
import base64, json, math, subprocess, sys, tempfile, zipfile
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"
back, front = (200, 100, 20, 64), (50, 150, 250, 128)
alpha = min(1, back[3] / 255 + front[3] / 255)
expected = tuple(math.floor(min(1, back[i]/255 * back[3]/255 + front[i]/255 * front[3]/255) / alpha * 255 + .5) for i in range(3)) + (math.floor(alpha * 255 + .5),)

def png(color):
    data = BytesIO()
    Image.new("RGBA", (2,2), color).save(data, "PNG")
    return data.getvalue()

with tempfile.TemporaryDirectory(prefix="moonora-plus-") as directory:
    work = Path(directory)
    source, result = work / "plus.ora", work / "result.png"
    with zipfile.ZipFile(source, "w") as z:
        z.writestr("mimetype", "image/openraster", compress_type=0)
        z.writestr("stack.xml", '<image w="2" h="2"><stack><layer src="data/front.png" composite-op="svg:plus"/><layer src="data/back.png"/></stack></image>')
        z.writestr("data/front.png", png(front))
        z.writestr("data/back.png", png(back))
        z.writestr("mergedimage.png", png(expected))
    rendered = subprocess.run(["node",str(CLI),"render",str(source),str(result)],cwd=ROOT,check=True,capture_output=True,text=True)
    assert "Krita" in rendered.stderr and "svg:plus" in rendered.stderr
    actual = Image.open(result).convert("RGBA").getpixel((0,0))
    assert actual == expected, (actual, expected)
    bridge = ROOT / "_build/js/debug/build/bridge/bridge.js"
    probe = '''import {request} from %s;
const run=q=>JSON.parse(request(JSON.stringify(q)));
const s=run({action:'open',data:process.argv[1]});
if(!s.ok || s.editable!==true || !s.warning.includes('Krita'))throw Error('Missing open warning');
const p=s.tree[0];
const edited=run({action:'edit',path:[0],name:p.name,x:1,y:0,opacity:1,visible:true,op:p.op});
if(!edited.ok || !edited.warning.includes('Krita'))throw Error('Warning lost after edit');
if(!run({action:'undo'}).warning.includes('Krita'))throw Error('Warning lost on undo');
const before=run({action:'export'}).data;
for(const visible of ['false',0,null]){
 const bad=run({action:'edit',path:[0],name:p.name,x:0,y:0,opacity:1,visible,op:p.op});
 if(bad.ok || run({action:'export'}).data!==before)throw Error('Invalid boolean changed state');
}
''' % json.dumps(bridge.as_uri())
    subprocess.run(["node","--input-type=module","-e",probe,base64.b64encode(source.read_bytes()).decode()],check=True)
    evidence = {"source":front,"backdrop":back,"w3c_expected":expected,"moonbit":actual,"krita":None,"krita_max_channel_difference":None}
    if len(sys.argv)>1:
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        exe = str(Path(sys.argv[1]).resolve())
        version = subprocess.run([exe,"--version"],capture_output=True,text=True,startupinfo=startup,check=True).stdout.strip()
        subprocess.run([exe,"--nosplash","--export","--export-filename",str(work / "krita.png"),str(source)],capture_output=True,check=True,startupinfo=startup,timeout=90)
        observed = Image.open(work / "krita.png").convert("RGBA").getpixel((0,0))
        evidence.update(krita=observed,krita_version=version,krita_max_channel_difference=max(abs(a-b) for a,b in zip(expected,observed)))
    out = ROOT / "_build/plus-validation.json"
    out.write_text(json.dumps(evidence,indent=2),encoding="utf-8")
print("PASS: independent W3C plus pixel", expected, "; CLI/bridge warnings survive edits/undo; wrong booleans leave state unchanged")
if evidence["krita"] is not None:
    print("Live Krita pixel:",evidence["krita"],"maximum channel difference:",evidence["krita_max_channel_difference"])
