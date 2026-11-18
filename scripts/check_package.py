"""Check planned core files and an isolated source-tree consumer, without release output.

Moon 0.1.20261104 still writes an archive for --list. Redirect that side effect
into an automatically deleted temporary directory. Consumer uses listed source
files; actual release-archive/registry checks remain post-acceptance work.
"""
from pathlib import Path
import argparse, json, re, shutil, subprocess, tempfile
from check_licenses import validate_tree, _referenced_files
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--target", choices=["js", "native"], default="js")
args = parser.parse_args()
manifest, _ = validate_tree()
text = (ROOT / "moon.mod").read_text(encoding="utf-8")
name = re.search(r'^name\s*=\s*"([^"]+)"', text, re.M)[1]
version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)[1]
with tempfile.TemporaryDirectory(prefix="moonora-source-consumer-") as folder:
    workspace = Path(folder)
    listing = subprocess.run(["moon", "package", "--list", "--frozen", "--target-dir", str(workspace / "list-build")], cwd=ROOT, check=True, capture_output=True, text=True, encoding="utf-8")
    files = sorted({line.strip().replace("\\", "/") for line in (listing.stdout + listing.stderr).splitlines() if (ROOT / line.strip()).is_file()})
    required = _referenced_files(manifest) | {"moon.mod", "moon.pkg", "README.md", "operations.mbt", "examples/roundtrip/main.mbt", "docs/API.zh-CN.md"}
    assert required <= set(files), required - set(files)
    assert not any(set(Path(file).parts) & {"web", "bridge", "fixtures", "tests", "scripts", "_build", ".git", "node_modules", ".mooncakes"} for file in files)
    size = sum((ROOT / file).stat().st_size for file in files)
    assert size < 2 * 1024 * 1024, size
    (ROOT / "_build").mkdir(exist_ok=True)
    (ROOT / "_build/core-file-list.json").write_text(json.dumps({"module": name, "version": version, "files": files, "uncompressed_bytes": size}, ensure_ascii=False, indent=2), encoding="utf-8")
    package, consumer = workspace / "package", workspace / "consumer"
    for file in files:
        destination = package / file
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / file, destination)
    consumer.mkdir()
    (consumer / "moon.mod").write_text(f'name = "local/consumer"\nimport {{ "{name}@{version}", "moonbitlang/x@0.5.7" }}\n', encoding="utf-8")
    shutil.copyfile(ROOT / "examples/roundtrip/moon.pkg", consumer / "moon.pkg")
    original = (ROOT / "examples/roundtrip/main.mbt").read_text(encoding="utf-8")
    main = consumer / "main.mbt"
    main.write_text(original, encoding="utf-8")
    subprocess.run(["moon", "work", "init"], cwd=workspace, check=True)
    subprocess.run(["moon", "work", "use", "package", "consumer"], cwd=workspace, check=True)
    subprocess.run(["moon", "run", ".", "--target", args.target, "--deny-warn"], cwd=consumer, check=True)
    prefix = 'fn main raise { let image=@ora.Image::new(1,1,[255,0,0,255]); let p=@ora.Properties::new("red"); let doc=@ora.Document::new(1,1,[@ora.Node::Layer(p,image)]); '
    for invalid in ['image.pixels.clear()', 'p.extra.clear()', 'doc.children.clear()', 'doc.resources.clear()', 'doc.image_attributes.clear()']:
        main.write_text(prefix + invalid + ' }\n', encoding="utf-8")
        check = subprocess.run(["moon", "check", "--target", "js"], cwd=consumer, capture_output=True, text=True, encoding="utf-8")
        assert check.returncode != 0 and ("no field" in check.stderr.lower() or "private" in check.stderr.lower()), invalid + check.stderr
    main.write_text(original, encoding="utf-8")
print(f"PASS: {len(files)} planned source files, {size / 1024:.1f} KiB; isolated {args.target} consumer and 5 private-storage compile rejections; no final release output")
