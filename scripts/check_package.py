"""Validate and consume the exact package generated for moon.mod's current version."""
from pathlib import Path
import re, subprocess, tempfile, zipfile
root = Path(__file__).resolve().parents[1]
text = (root / "moon.mod").read_text()
name = re.search(r'^name\s*=\s*"([^"]+)"', text, re.M)[1]
version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)[1]
subprocess.run(["moon", "package"], cwd=root, check=True)
archive = root / "_build/publish" / (name.replace("/", "-") + "-" + version + ".zip")
with tempfile.TemporaryDirectory(prefix="moonora-consumer-") as folder:
    workspace = Path(folder)
    package = workspace / "package"
    package.mkdir()
    with zipfile.ZipFile(archive) as z:
        members = z.namelist()
        assert "moon.mod" in members and "LICENSE" in members
        assert any(s.startswith("LICENSES/") for s in members)
        assert not any(".git/" in s or "proposal" in s.lower() for s in members)
        manifest = z.read("moon.mod").decode()
        assert f'"{name}"' in manifest and f'"{version}"' in manifest
        z.extractall(package)
    consumer = workspace / "consumer"
    consumer.mkdir()
    (consumer / "moon.mod").write_text(f'name = "local/consumer"\nimport {{ "{name}@{version}" }}\n')
    (consumer / "moon.pkg").write_text(f'import {{ "{name}" @ora }}\noptions("is-main": true)\n')
    (consumer / "main.mbt").write_text('fn main raise { let image=@ora.Image::new(1,1,[255,0,0,255]); let doc=@ora.Document::new(1,1,[@ora.Node::Layer(@ora.Properties::new("red"),image)]); let loaded=@ora.read(doc.write()); assert_eq(loaded.render().pixels()[0],255); println("consumer PASS") }\n')
    subprocess.run(["moon", "work", "init"], cwd=workspace, check=True)
    subprocess.run(["moon", "work", "use", "package", "consumer"], cwd=workspace, check=True)
    subprocess.run(["moon", "run", ".", "--target", "js"], cwd=consumer, check=True)
print("PASS: exact version archive, licenses and independent package consumer")

