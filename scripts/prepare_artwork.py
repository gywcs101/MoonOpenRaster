"""Convert the author's original layers into a reproducible, web-sized ORA.

Usage: python scripts/prepare_artwork.py SOURCE.zip KRITA.exe
No new painted content is added. The archive hash pins the reviewed source.
"""
from pathlib import Path
import hashlib
import io
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image, ImageCms

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = "a8b84d86f645bc4ccef4a4a4519023f2f2cdeac36ad05b7235c95a9630c28895"
NAMES = {
    "dessin": "绘画（原稿组）",
    "ink - thick (for tee-shirts)": "粗线稿（T 恤备选）",
    "ink": "线稿",
    "retouches": "修饰",
    "ombrage": "阴影",
    "applat de couleurs": "底色",
    "sketch": "草稿",
    "fond": "背景",
}


def krita_export(exe, source, output):
    startup = None
    if sys.platform == "win32":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
    subprocess.run(
        [str(exe), "--nosplash", "--export", "--export-filename", str(output), str(source)],
        check=True, capture_output=True, timeout=120, startupinfo=startup,
    )


def prepare(source, krita):
    assert hashlib.sha256(source.read_bytes()).hexdigest() == SOURCE_SHA256, "Unexpected source archive"
    with tempfile.TemporaryDirectory(prefix="moonora-artwork-") as folder:
        work = Path(folder)
        with zipfile.ZipFile(source) as archive:
            name, = archive.namelist()
            kra = work / "source.kra"
            kra.write_bytes(archive.read(name))
        original = work / "original.ora"
        krita_export(krita, kra, original)
        with zipfile.ZipFile(original) as archive:
            root = ET.fromstring(archive.read("stack.xml"))
            ratio = 1000 / max(int(root.get("w")), int(root.get("h")))
            root.set("w", str(round(int(root.get("w")) * ratio)))
            root.set("h", str(round(int(root.get("h")) * ratio)))
            root.set("name", "自由之都 · 原始分层插画")
            blobs = {}
            manifest = []
            for element in root.iter():
                old = element.get("name")
                if old in NAMES:
                    element.set("name", NAMES[old])
                if element.tag != "layer":
                    continue
                path = element.get("src")
                image = Image.open(io.BytesIO(archive.read(path)))
                if image.info.get("icc_profile"):
                    image = ImageCms.profileToProfile(
                        image, ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"])),
                        ImageCms.createProfile("sRGB"), outputMode="RGBA",
                    )
                else:
                    image = image.convert("RGBA")
                x, y = int(element.get("x", 0)), int(element.get("y", 0))
                nx, ny = round(x * ratio), round(y * ratio)
                size = (max(1, round((x + image.width) * ratio) - nx), max(1, round((y + image.height) * ratio) - ny))
                image = image.resize(size, Image.Resampling.LANCZOS)
                # Do not silently propagate a profile after conversion to explicit sRGB.
                clean = Image.frombytes("RGBA", image.size, image.tobytes())
                buffer = io.BytesIO()
                clean.save(buffer, format="PNG")
                blobs[path] = buffer.getvalue()
                element.set("x", str(nx))
                element.set("y", str(ny))
                manifest.append({"original_name": old, "name": element.get("name"), "src": path, "size": size, "x": nx, "y": ny})
            raw = work / "web-source.ora"
            with zipfile.ZipFile(raw, "w", zipfile.ZIP_DEFLATED) as output:
                output.writestr("mimetype", "image/openraster", compress_type=zipfile.ZIP_STORED)
                output.writestr("stack.xml", ET.tostring(root, encoding="utf-8"))
                for name, data in blobs.items():
                    output.writestr(name, data)
            # Both applications render the exact same converted layer resources.
            reference = work / "krita.png"
            krita_export(krita, raw, reference)
            with zipfile.ZipFile(raw) as output:
                files = [(n, output.read(n)) for n in output.namelist()]
            # Seed the merged image for inspect(); replace it with MoonBit's result below.
            with zipfile.ZipFile(raw, "w", zipfile.ZIP_DEFLATED) as output:
                for name, data in files:
                    output.writestr(name, data, compress_type=zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED)
                output.writestr("mergedimage.png", reference.read_bytes())
            script = """
                import {request} from './web/core.js';
                import fs from 'node:fs';
                const run=q=>{const r=JSON.parse(request(JSON.stringify(q)));if(!r.ok)throw Error(r.error);return r;};
                const r=run({action:'open',data:fs.readFileSync(process.argv[1]).toString('base64')});
                if(r.editable===false)throw Error(r.warning);
                fs.writeFileSync('web/assets/capitole.ora',Buffer.from(run({action:'export'}).data,'base64'));
                fs.writeFileSync('web/assets/capitole-preview.png',Buffer.from(r.png,'base64'));
            """
            subprocess.run(["node", "--input-type=module", "-e", script, str(raw)], cwd=ROOT, check=True)
            actual = Image.open(ROOT / "web/assets/capitole-preview.png").convert("RGBA")
            expected = Image.open(reference).convert("RGBA")
            differences = [abs(a - b) for a, b in zip(actual.tobytes(), expected.tobytes())]
            report = {"source_sha256": SOURCE_SHA256, "canvas": actual.size, "layers": manifest,
                      "krita_max_channel_error": max(differences), "krita_mean_channel_error": sum(differences) / len(differences)}
            (ROOT / "fixtures/artwork-validation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps(report, ensure_ascii=False, indent=2))
            assert max(differences) <= 2, "Investigate real-work compatibility before shipping this sample"
            (ROOT / "fixtures/capitole-krita.png").write_bytes(reference.read_bytes())


if __name__ == "__main__":
    prepare(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
