"""Check full license copies, asset coverage and the exact distributed bundles.

No credentials or network access are required. Run standalone, or import
validate_bundle from the library/web packaging checks.
"""
from pathlib import Path
from fnmatch import fnmatchcase
import hashlib
import json
import re
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "LICENSES/manifest.json"
def text_hash(data):
    return hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest()


BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".ico", ".svg", ".ora", ".woff", ".woff2"}


def _referenced_files(manifest):
    files = {"LICENSE", "LICENSES/manifest.json", "LICENSES/README.md", "THIRD_PARTY.md"}
    for item in manifest["license_texts"]:
        files.add(item["file"])
    for item in manifest["runtime_dependencies"] + manifest["asset_groups"]:
        for key in ["license_file", "notice_file", "additional_notice_file"]:
            if key in item:
                files.add(item[key])
    return files


def _coverage(name, manifest):
    matches = [group for group in manifest["asset_groups"] if any(fnmatchcase(name, p) for p in group["patterns"])]
    assert len(matches) == 1, f"Asset needs exactly one source/license mapping: {name}"


def validate_tree(root=ROOT):
    manifest = json.loads((root / "LICENSES/manifest.json").read_text(encoding="utf-8"))
    for name in _referenced_files(manifest):
        assert (root / name).is_file(), f"Missing distributed license/notice: {name}"
    for item in manifest["license_texts"]:
        data = (root / item["file"]).read_bytes()
        assert text_hash(data) == item["sha256_lf"], f"License text changed: {item['file']}"
        text = data.decode("utf-8")
        if item["id"] == "Apache-2.0":
            assert len(data) > 10000 and "END OF TERMS AND CONDITIONS" in text
        elif item["id"] == "CC-BY-4.0":
            assert len(data) > 18000 and "Section 8 -- Interpretation" in text
        elif item["id"] == "OFL-1.1":
            assert len(data) > 4000 and "Copyright" in text and "DISCLAIMER" in text
    count = 0
    for directory in [root / "web/assets", root / "fixtures"]:
        for path in directory.rglob("*"):
            if path.is_file() and path.suffix.lower() in BINARY_SUFFIXES:
                _coverage(path.relative_to(root).as_posix(), manifest)
                count += 1
    # If installed sources are available, compare the actual upstream license,
    # resolved version and any upstream NOTICE with the distributed copies.
    for component in manifest["runtime_dependencies"]:
        directory = root / ".mooncakes" / component["module"]
        is_core = component["module"] == "moonbitlang/core"
        if is_core and shutil.which("moon"):
            directory = Path(shutil.which("moon")).resolve().parent.parent / "lib/core"
        if "notice_sha256_lf" in component:
            assert text_hash((root / component["notice_file"]).read_bytes()) == component["notice_sha256_lf"], component["module"]
        if not directory.is_dir():
            continue
        module = directory / "moon.mod"
        if module.exists() and not is_core:
            version = re.search(r'^version\s*=\s*"([^"]+)"', module.read_text(encoding="utf-8"), re.M)
            assert version and version[1] == component["version"], f"Update resolved component notice: {component['module']}"
        source_license = directory / "LICENSE"
        if source_license.exists():
            assert text_hash(source_license.read_bytes()) == text_hash((root / component["license_file"]).read_bytes()), component["module"]
        notice = directory / "NOTICE"
        if notice.exists():
            assert "notice_file" in component, f"Missing upstream NOTICE: {component['module']}"
            assert text_hash(notice.read_bytes()) == text_hash((root / component["notice_file"]).read_bytes()), component["module"]
    return manifest, count


def validate_bundle(filename, web=False):
    manifest, _ = validate_tree()
    with zipfile.ZipFile(filename) as archive:
        names = set(archive.namelist())
        assert _referenced_files(manifest) <= names, "Bundle omits one or more required license/notice files"
        for name in _referenced_files(manifest):
            assert archive.read(name) == (ROOT / name).read_bytes(), f"Stale bundle notice: {name}"
        for name in names:
            assert not ({"node_modules", ".mooncakes", ".git"} & set(Path(name).parts)), f"Unexpected vendored/build content: {name}"
            if Path(name).suffix.lower() in BINARY_SUFFIXES:
                _coverage("web/" + name if web else name, manifest)
    return True


def check_regressions(manifest):
    """Exercise the two rejected-submission cases against distribution bytes."""
    required = _referenced_files(manifest)
    with tempfile.TemporaryDirectory(prefix="moonora-license-check-") as folder:
        for case in ["missing-artwork-license", "truncated-core-notice"]:
            filename = Path(folder) / (case + ".zip")
            with zipfile.ZipFile(filename, "w") as archive:
                for name in required:
                    if case == "missing-artwork-license" and name == "LICENSES/CC-BY-4.0.txt":
                        continue
                    data = (ROOT / name).read_bytes()
                    if case == "truncated-core-notice" and name == "LICENSES/moonbitlang-core-NOTICE":
                        data = b"MoonBit core uses Apache-2.0; see the upstream website.\n"
                    archive.writestr(name, data)
            try:
                validate_bundle(filename)
            except AssertionError:
                continue
            raise AssertionError("Incomplete redistribution unexpectedly accepted: " + case)


if __name__ == "__main__":
    manifest, count = validate_tree()
    check_regressions(manifest)
    print(f"PASS: {count} binary assets mapped to source and full license; {len(manifest['runtime_dependencies'])} runtime components covered")
    print("PASS: incomplete license copy and shortened upstream NOTICE are rejected")
