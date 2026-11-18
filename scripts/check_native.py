"""Exercise actual native CLI filesystem input/output on each CI operating system."""
from pathlib import Path
import json, subprocess, tempfile, zipfile
ROOT = Path(__file__).resolve().parents[1]
fixture = ROOT / "fixtures/krita-5.3.4.ora"

def run(*args, success=True):
    result = subprocess.run(["moon", "run", "cmd/main", "--target", "native", "--", *map(str,args)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    assert (result.returncode == 0) == success, result.stderr
    return result

with tempfile.TemporaryDirectory(prefix="moonora-native-") as directory:
    work = Path(directory)
    info = json.loads(run("inspect", fixture).stdout)
    assert info["width"] > 0 and info["tree"]
    run("render", fixture, work / "原生合成.png")
    assert (work / "原生合成.png").read_bytes().startswith(b"\x89PNG")
    edits = work / "编辑.json"
    edits.write_text(json.dumps([{"path":[0,0],"name":"原生中文编辑","x":-3}]), encoding="utf-8")
    run("edit", fixture, work / "修改.ora", edits)
    reopened = json.loads(run("inspect", work / "修改.ora").stdout)
    assert reopened["tree"][0]["children"][0]["name"] == "原生中文编辑"
    assert reopened["tree"][0]["children"][0]["x"] == -3
    with zipfile.ZipFile(work / "修改.ora") as z:
        assert len(z.namelist()) == len(set(z.namelist()))
    run("edit", fixture, work / "修改.ora", edits, success=False)
    edits.write_text('[{"path":[0,0],"x":1.5}]')
    run("edit", fixture, work / "不应生成.ora", edits, success=False)
    assert not (work / "不应生成.ora").exists()
print("PASS: native CLI inspect/render/edit, Unicode paths/names, reopen, overwrite and invalid-input protection")
