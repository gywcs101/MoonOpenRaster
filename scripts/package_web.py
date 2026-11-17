"""Build a self-contained local web bundle with dependency licenses."""
from pathlib import Path
import subprocess, zipfile, json
root=Path(__file__).resolve().parents[1]
subprocess.run(["python", "scripts/build_web.py"],cwd=root,check=True)
out=root / "_build/publish/MoonOpenRaster-web.zip"
out.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as z:
    for name in ["index.html","style.css","app.js","core.js","worker.js","samples.js"]:
        z.write(root/"web"/name,name)
    for p in (root/"web/assets").rglob("*"):
        if p.is_file():z.write(p,"assets/"+str(p.relative_to(root/"web/assets")).replace("\\","/"))
    z.write(root/"LICENSE","LICENSE")
    z.write(root/"THIRD_PARTY.md","THIRD_PARTY.md")
    z.write(root/"docs/WORKBENCH.zh-CN.md", "使用说明.md")
    for p in (root/"LICENSES").iterdir():
        if p.is_file():z.write(p,"LICENSES/"+p.name)
    z.writestr("README.txt","MoonOpenRaster local workbench\nExtract this archive, run python -m http.server 8765 --bind 127.0.0.1 in that directory and open http://127.0.0.1:8765/.\nAll processing is local. No remote resources are required.\n")
with zipfile.ZipFile(out) as z:
    names = set(z.namelist())
    catalog = json.loads(z.read("assets/sample-catalog.json"))
    for sample in catalog["samples"]:
        required = [sample["file"], sample["cover"], sample["practice"]["file"], sample["practice"]["start"], sample["practice"]["goal"]]
        for step in sample["practice"]["steps"]:
            required.extend(check["asset"] for check in step.get("checks", []) if "asset" in check)
        assert all(name in names for name in required), sample["id"]
    assert "samples.js" in names and "LICENSES/sample-artworks-NOTICE.txt" in names
print(out)
