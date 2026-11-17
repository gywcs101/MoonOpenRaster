"""Prepare authentic layered samples and clearly labelled practice variants.

Run after downloading the hash-pinned source zips into ../.tools/artwork/.
Krita exports are cached there. See LICENSES/sample-artworks-NOTICE.txt.
Only the practice variants deliberately change properties or background color.
"""
from pathlib import Path
import hashlib
import io
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from PIL import Image, ImageCms, ImageChops
from prepare_artwork import krita_export

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT.parent / ".tools/artwork"
OUT = ROOT / "web/assets/samples"
WORK = ROOT / "_build/sample-build"
SOURCES = [
    ("bloom", "2022-03-02_In-Bloom_by-David-Revoy", "d5f8eaf52ca88219509ee77d0c6dd1ff9efa512ddc88c5d6ea8cc95c959cdc44", {
        "/": "绘画", "signature": "署名", "paint-over2": "细节补绘", "paint-over1": "轮廓补绘", "drawing": "铅笔线稿", "precolor": "预设色彩", "value": "明暗底稿", "---": "纸张底色",
    }),
    ("house", "2021-05-19_Spooky-Cute-House_by-David-Revoy", "3d37b530d10c7ba686bbd54d7da0870896996a4c58f7d7d6bc5ae5e886af4f73", {
        "persp": "透视参考组", "z__parralal_verti_8K_BLUE.png": "蓝色透视线", "y__distant_4K_GREEN.png": "绿色透视线", "x__distant_4K_RED.png": "红色透视线", "hl": "辅助水平线", "/": "房屋绘制", "sign": "署名", "post": "后期修饰", "over": "前景绘制", "under": "基础绘制", "---": "背景底稿", "thumb": "构图小稿",
    }),
    ("rain", "2022-12-06_Rain-City_by-David-Revoy", "b4fdccfd7858544bbb5dbc9ca3b89dc5a3897f714d06788b2c8010ba7f64ab92", {
        "persp": "透视参考线", "composition": "构图检查", "post-effects": "后期效果", "rain": "雨幕", "vignette": "暗角", "fix": "修饰", "enhancing": "细节增强", "theme change": "色调绘制", "block 1": "场景铺色", "idea": "构思底稿",
    }),
]


def normalize(identifier, stem, expected_hash, names, krita):
    archive = TOOLS / (stem + ".zip")
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected_hash
    original = TOOLS / (stem + ".ora")
    with zipfile.ZipFile(archive) as a:
        kra_bytes = a.read(next(n for n in a.namelist() if n.endswith(".kra")))
    if not original.exists():
        source_kra = WORK / (identifier + "-source.kra")
        source_kra.write_bytes(kra_bytes)
        krita_export(krita, source_kra, original)
    with zipfile.ZipFile(io.BytesIO(kra_bytes)) as kra, zipfile.ZipFile(original) as a:
        original_error = max(v[1] for v in ImageChops.difference(
            Image.open(io.BytesIO(kra.read("mergedimage.png"))).convert("RGBA"),
            Image.open(io.BytesIO(a.read("mergedimage.png"))).convert("RGBA"),
        ).getextrema())
        assert original_error <= 2, (identifier, "KRA to ORA", original_error)
        root = ET.fromstring(a.read("stack.xml"))
        ratio = min(1, 768 / max(int(root.get("w")), int(root.get("h"))))
        root.set("w", str(round(int(root.get("w")) * ratio)))
        root.set("h", str(round(int(root.get("h")) * ratio)))
        root.set("name", {"bloom": "花间少女", "house": "林间小屋", "rain": "雨城"}[identifier])
        blobs, layer_map = {}, []
        for e in root.iter():
            old = e.get("name")
            if old in names:
                e.set("name", names[old])
            if e.tag != "layer":
                continue
            image = Image.open(io.BytesIO(a.read(e.get("src"))))
            if image.info.get("icc_profile"):
                image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"])), ImageCms.createProfile("sRGB"), outputMode="RGBA")
            image = image.convert("RGBA")
            x, y = int(e.get("x", 0)), int(e.get("y", 0))
            nx, ny = round(x * ratio), round(y * ratio)
            size = (max(1, round((x + image.width) * ratio) - nx), max(1, round((y + image.height) * ratio) - ny))
            image = image.resize(size, Image.Resampling.LANCZOS)
            clean = Image.frombytes("RGBA", image.size, image.tobytes())
            data = io.BytesIO()
            clean.save(data, "PNG")
            blobs[e.get("src")] = data.getvalue()
            e.set("x", str(nx)); e.set("y", str(ny))
            layer_map.append({"original": old, "name": e.get("name"), "size": size})
        original_preview = Image.open(io.BytesIO(a.read("mergedimage.png"))).convert("RGBA")
        original_preview = original_preview.resize((int(root.get("w")), int(root.get("h"))), Image.Resampling.LANCZOS)
        raw = WORK / (identifier + ".ora")
        with zipfile.ZipFile(raw, "w", zipfile.ZIP_DEFLATED) as result:
            result.writestr("mimetype", "image/openraster", compress_type=zipfile.ZIP_STORED)
            result.writestr("stack.xml", ET.tostring(root, encoding="utf-8"))
            for path, data in blobs.items(): result.writestr(path, data)
            png = io.BytesIO(); original_preview.save(png, "PNG")
            result.writestr("mergedimage.png", png.getvalue())
        reference = ROOT / "fixtures/samples" / (identifier + "-krita.png")
        krita_export(krita, raw, reference)
        return {"id": identifier, "stem": stem, "sha256": expected_hash, "original_kra_ora_max_error": original_error, "layers": layer_map}


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True); WORK.mkdir(parents=True, exist_ok=True)
    (ROOT / "fixtures/samples").mkdir(exist_ok=True)
    Image.new("RGBA", (1000, 1000), "#c2ddc8").save(WORK / "capitole-tinted-background.png")
    krita = Path(sys.argv[1]).resolve()
    reports = [normalize(*source, krita) for source in SOURCES]
    (WORK / "sources.json").write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding="utf-8")
    subprocess.run(["node", "scripts/build_sample_catalog.mjs"], cwd=ROOT, check=True)
    catalog = json.loads((ROOT / "web/assets/sample-catalog.json").read_text(encoding="utf-8"))
    for sample in catalog["samples"][1:]:
        with zipfile.ZipFile(ROOT / "web" / sample["file"]) as a:
            actual = Image.open(io.BytesIO(a.read("mergedimage.png"))).convert("RGBA")
        expected = Image.open(ROOT / "fixtures/samples" / (sample["id"] + "-krita.png")).convert("RGBA")
        error = max(v[1] for v in ImageChops.difference(actual, expected).getextrema())
        print(sample["id"], "converted ORA vs Krita maximum channel error", error)
        assert error <= 2, (sample["id"], error)
        report = next(r for r in reports if r["id"] == sample["id"])
        report["web_ora_krita_max_error"] = error
    (ROOT / "fixtures/sample-validation.json").write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding="utf-8")
