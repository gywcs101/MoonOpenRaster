"""Build a self-contained local web bundle with dependency licenses."""
from pathlib import Path
import subprocess, zipfile
root=Path(__file__).resolve().parents[1]
subprocess.run(["python", "scripts/build_web.py"],cwd=root,check=True)
out=root / "_build/publish/MoonOpenRaster-web.zip"
out.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as z:
    for name in ["index.html","style.css","app.js","core.js"]:
        z.write(root/"web"/name,name)
    z.write(root/"LICENSE","LICENSE")
    z.write(root/"THIRD_PARTY.md","THIRD_PARTY.md")
    for p in (root/"LICENSES").iterdir():
        if p.is_file():z.write(p,"LICENSES/"+p.name)
    z.writestr("README.txt","MoonOpenRaster local workbench\nExtract this archive, run python -m http.server 8765 --bind 127.0.0.1 in that directory and open http://127.0.0.1:8765/.\nAll processing is local. No remote resources are required.\n")
print(out)
