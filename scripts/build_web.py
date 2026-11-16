from pathlib import Path
import subprocess, shutil
root = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "build", "--target", "js"], cwd=root, check=True)
shutil.copyfile(root / "_build/js/debug/build/bridge/bridge.js", root / "web/core.js")
print("Built web/core.js. Serve web/ with a local static server.")
