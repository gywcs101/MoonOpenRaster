"""Check committed Krita evidence, optionally perform live Krita export and reopen."""
from pathlib import Path
import subprocess, tempfile, json, zipfile, io, sys
from PIL import Image
root = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js"], cwd=root, check=True)
cli = root / "_build/js/debug/build/cmd/main/main.js"
def run(*args):
    subprocess.run(["node", str(cli), *map(str, args)], cwd=root, check=True)
def compare(a, b, tolerance=0):
    a, b = a.convert("RGBA"), b.convert("RGBA")
    assert a.size == b.size
    error = max(abs(x-y) for x,y in zip(a.tobytes(),b.tobytes()))
    assert error <= tolerance, error
    return error
with tempfile.TemporaryDirectory(prefix="moonora-krita-") as folder:
    p = Path(folder)
    fixture = root / "fixtures/krita-5.3.4.ora"
    run("render", fixture, p / "render.png")
    compare(Image.open(p / "render.png"), Image.open(root / "fixtures/krita-5.3.4.png"))
    (p / "edits.json").write_text(json.dumps([{"path":[0,0],"name":"Edited amber","x":140,"y":80,"visible":True,"opacity":0.5,"composite_op":"svg:multiply"}]))
    run("edit", fixture, p / "edited.ora", p / "edits.json")
    if len(sys.argv)>1:
        exe = str(Path(sys.argv[1]).resolve())
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        for suffix in ["png", "ora"]:
            subprocess.run([exe,"--nosplash","--export","--export-filename",str(p / ("reopened."+suffix)),str(p / "edited.ora")],check=True,timeout=90,startupinfo=startup,capture_output=True)
        with zipfile.ZipFile(p / "edited.ora") as z:
            error=compare(Image.open(io.BytesIO(z.read("mergedimage.png"))),Image.open(p / "reopened.png"),2)
        run("render",p / "reopened.ora",p / "roundtrip.png")
        compare(Image.open(p / "roundtrip.png"),Image.open(p / "reopened.png"),2)
        print("PASS: live Krita edit/export/reopen; maximum channel error",error)
print("PASS: independent Krita fixture renders exactly")
