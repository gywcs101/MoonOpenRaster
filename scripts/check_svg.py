"""Check vector-layer preservation and independent SVG + RGBA16 composition."""
import argparse
import base64
from io import BytesIO
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from check_rgba16 import decode_rgba, png

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "_build/svg-roundtrip"
ATLAS = ROOT / "web/assets/import-samples"
SVG = (
    b'<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2">'
    b"<style>@import '../paint.css';</style>"
    b'<defs><rect id="mark" class="accent" width="1" height="2"/></defs>'
    b'<use href="#mark"/></svg>'
)
CSS = b'.accent { fill: #ff0000; }'
BASE = (10001, 20002, 30003, 65535)


def check_atlas(path):
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read("stack.xml"))
        layer = next(n for n in root.iter("layer") if n.get("name") == "contours")
        assert (layer.get("x"), layer.get("y")) == ("30", "58")
        assert layer.get("src").endswith(".svg")
        assert archive.read(layer.get("src")) == (ATLAS / "contours.svg").read_bytes()
        terrain = next(n for n in root.iter("layer") if n.get("name") == "高程窗口")
        assert decode_rgba(archive.read(terrain.get("src")))[2] == 16
        assert archive.read("mergedimage.png") == (ATLAS / "atlas-goal.png").read_bytes()
    print("PASS: atlas retains exact SVG and 16-bit terrain after saving")


def check_font_layer(cli, variant="font"):
    embedded = variant == "embedded-font"
    spans = variant == "font-spans"
    declaration = variant == "font-stylesheet-pi"
    imported = variant == "font-stylesheet" or declaration
    cascade = variant == "font-css-cascade"
    centered = variant == "font-centered-spans"
    spacing = variant == "font-length-spacing"
    stretched = variant == "font-length-glyphs"
    letter_spacing = variant == "font-letter-spacing"
    weighted = variant == "font-weight"
    slanted = variant == "font-style"
    multiple_sources = variant == "font-alternate-sources"
    relative_size = variant == "font-relative-size"
    external = variant == "font-svg-resource"
    path_external = variant == "font-path-resource"
    path_text = variant == "font-path" or path_external
    positions = variant == "font-position-list"
    stem = variant
    source = OUT / f"{stem}-input.ora"
    edited = OUT / f"{stem}-edited.ora"
    edited.unlink(missing_ok=True)
    font = (ROOT / "fixtures/ora-test.ttf").read_bytes()
    uri = "data:font/ttf;base64," + base64.b64encode(font).decode() if embedded else "../font/%E6%B5%8B%E8%AF%95.ttf"
    face = f'@font-face {{ font-family: OraTest; src: url("{uri}"); }}'
    if multiple_sources:
        face = f'@font-face {{ font-family: OraTest; src: local("Uninstalled"), URL("../font/unsupported.woff"), url("{uri}") format("truetype"); }}'
    styles = "@import '../styles/level/index.css';" if imported else face
    if weighted or slanted:
        descriptor = "font-weight: 700" if weighted else "font-style: italic"
        styles = f'@font-face {{ font-family: OraTest; src: url("../font/alternate.ttf"); {descriptor}; }}' + styles
    if cascade:
        styles += " svg .label { font-family: Absent, OraTest; font-size: 8px; } text { fill: red; } path { fill: blue; }"
    text = 'A<tspan x="7" dx="1" y="7" dy="1"><tspan>中</tspan></tspan>' if spans else "A中"
    if path_text:
        definition = '<defs><path id="baseline" transform="translate(0 2)" d="M0 6 c2 0 5 0 8 0 s5 0 8 0"/></defs>'
        path_resource = f'<svg xmlns="http://www.w3.org/2000/svg">{definition}</svg>'
        position_attrs = ''
        text = '<textPath href="#baseline" startOffset="0%">A<tspan>中</tspan></textPath>'
        if path_external:
            definition = ""
            text = text.replace("#baseline", "../paths/layout.svg#baseline")
    else:
        definition = ''
        position_attrs = 'x="0,7" y="8 7" dx="0 1" dy="0 1" rotate="0 0"' if positions else 'x="0" y="8"'
    if centered:
        position_attrs = 'x="8" y="8" text-anchor="middle"'
        text = "A<tspan>中</tspan>"
    if spacing or stretched:
        position_attrs += ' textLength="24" lengthAdjust="spacingAndGlyphs"' if stretched else ' textLength="20"'
    if letter_spacing:
        position_attrs += ' style="letter-spacing: .5em"'
    if weighted:
        position_attrs += ' font-weight="bolder"'
    if slanted:
        position_attrs += ' style="font-style: italic"'
    stylesheet = '<?xml-stylesheet type="text/css" href="../styles/level/index.css"?>' if declaration else ''
    inline_style = '' if declaration else f'<style>{styles}</style>'
    font_attributes = 'class="label"' if cascade else 'font-family="OraTest" font-size="8" fill="red"'
    parent_attrs = ""
    if relative_size:
        position_attrs = 'x="0" y="1em"'
        font_attributes = 'font-family="OraTest" font-size="50%" fill="red"'
        parent_attrs = ' font-size="16px"'
        text = 'A<tspan font-size="1em">中</tspan>'
    svg = (
        f'{stylesheet}<svg xmlns="http://www.w3.org/2000/svg" width="16" height="8"{parent_attrs}>'
        f'{inline_style}{definition}'
        f'<text {font_attributes} {position_attrs} id="label">{text}</text></svg>'
    ).encode()
    external_svg = svg
    if external:
        svg = b'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="8"><use href="../word/source.svg#label"/></svg>'
    red = (65535, 0, 0, 65535)

    def glyph_ink(x, y):
        if stretched:
            return (x < 6 and y >= 4) or (x >= 12 and y >= 2)
        if spacing or letter_spacing or weighted or slanted:
            return (x < 4 and y >= 4) or (x >= 12 and y >= 2)
        return (x < 4 and y >= 4) or (8 <= x < 14 and y >= 2)

    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="16" h="8" xres="96"><stack><layer name="Text" src="data/art/text.svg"/><layer name="Raster" src="data/base.png"/></stack></image>')
        archive.writestr("data/art/text.svg", svg)
        if external:
            archive.writestr("data/word/source.svg", external_svg)
        if path_external:
            archive.writestr("data/paths/layout.svg", path_resource)
        if not embedded:
            archive.writestr("data/font/测试.ttf", font)
        if multiple_sources:
            archive.writestr("data/font/unsupported.woff", b"invalid font")
        if weighted or slanted:
            # The glyphs share the first hmtx advance. Change it from 8 to 12 px
            # at the configured font size to distinguish the two faces.
            alternate = bytearray(font)
            count = struct.unpack_from(">H", font, 4)[0]
            metrics = next(offset for tag, _, offset, _ in struct.iter_unpack(
                ">4sIII", font[12:12 + count * 16]) if tag == b"hmtx")
            struct.pack_into(">H", alternate, metrics, 1500)
            archive.writestr("data/font/alternate.ttf", alternate)
        if imported:
            archive.writestr("data/styles/level/index.css", "@import 'font.css';")
            archive.writestr("data/styles/level/font.css", face.replace("../font/", "../../font/"))
        archive.writestr("data/base.png", png(16, 8, 16, lambda x, y: BASE))
        archive.writestr("mergedimage.png", png(16, 8, 16, lambda x, y: red if glyph_ink(x, y) else BASE))
        archive.writestr("Thumbnails/thumbnail.png", png(16, 8, 8, lambda x, y: (255, 0, 0, 255) if glyph_ink(x, y) else (39, 78, 117, 255)))

    changes = OUT / "font-edits.json"
    changes.write_text(json.dumps([{"path": [1], "x": 1}]), encoding="utf-8")
    subprocess.run(["node", str(cli), "edit", str(source), str(edited), str(changes)], check=True)
    with zipfile.ZipFile(edited) as archive:
        assert archive.read("data/art/text.svg") == svg
        if external:
            assert archive.read("data/word/source.svg") == external_svg
        if path_external:
            assert archive.read("data/paths/layout.svg") == path_resource.encode()
        if not embedded:
            assert archive.read("data/font/测试.ttf") == font
            assert archive.getinfo("data/font/测试.ttf").flag_bits & 0x800
        if imported:
            assert archive.read("data/styles/level/index.css") == b"@import 'font.css';"
            assert archive.read("data/styles/level/font.css").decode() == face.replace("../font/", "../../font/")
        root = ET.fromstring(archive.read("stack.xml"))
        assert (root.get("xres"), root.get("yres")) == ("96", "72")
        assert root.find("./stack/layer[@name='Raster']").get("x") == "1"
        expected = [red if glyph_ink(x, y) else BASE if x else (0, 0, 0, 0)
                    for y in range(8) for x in range(16)]
        width, height, depth, actual = decode_rgba(archive.read("mergedimage.png"))
        assert (width, height, depth) == (16, 8, 16)
        for index, (pixel, target) in enumerate(zip(actual, expected)):
            assert pixel == target, (index % 16, index // 16, pixel, target)
    print(f"PASS: {variant} matches its independent pixel oracle after moving an adjacent RGBA16 layer")



def check_default_font(cli):
    for generic, asset in (("sans-serif", "inter"), ("serif", "instrument-serif")):
        font = (ROOT / "web/assets" / (asset + ".woff2")).read_bytes()
        edited_images = []
        for variant in ("generic", "explicit"):
            source = OUT / f"{generic}-{variant}-input.ora"
            edited = OUT / f"{generic}-{variant}-edited.ora"
            edited.unlink(missing_ok=True)
            style = (
                '<style>@font-face { font-family: Reference; src: url("probe.woff2"); }</style>'
                if variant == "explicit" else ""
            )
            family = "Reference" if variant == "explicit" else generic
            attribute = f'font-family="{family}"' if family != "sans-serif" else ""
            svg = (
                '<svg xmlns="http://www.w3.org/2000/svg" width="84" height="32">'
                f'{style}<text x="2" y="23" font-size="20" {attribute} fill="red">A B</text></svg>'
            ).encode()
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("mimetype", "image/openraster")
                archive.writestr("stack.xml", '<image version="0.0.6" w="84" h="32"><stack><layer name="Text" src="data/text.svg"/><layer name="Raster" src="data/base.png"/></stack></image>')
                archive.writestr("data/text.svg", svg)
                if variant == "explicit":
                    archive.writestr("data/probe.woff2", font)
                archive.writestr("data/base.png", png(84, 32, 16, lambda x, y: BASE))
                archive.writestr("mergedimage.png", png(84, 32, 16, lambda x, y: BASE))
                archive.writestr("Thumbnails/thumbnail.png", png(84, 32, 8, lambda x, y: (0, 0, 255, 255)))
            subprocess.run(["node", str(cli), "edit", str(source), str(edited), str(OUT / "font-edits.json")], check=True)
            with zipfile.ZipFile(edited) as archive:
                assert archive.read("data/text.svg") == svg
                assert ET.fromstring(archive.read("stack.xml")).find("./stack/layer[@name='Raster']").get("x") == "1"
                composite = archive.read("mergedimage.png")
                width, height, depth, pixels = decode_rgba(composite)
                assert (width, height, depth) == (84, 32, 16)
                assert sum(red > 40000 and green < BASE[1] for red, green, _, _ in pixels) > 25
                edited_images.append(composite)
        assert edited_images[0] == edited_images[1]
        print(f"PASS: {generic} fallback is pixel-identical to using the same explicit font")


def check_svg_jpeg(cli):
    from PIL import Image

    buffer = BytesIO()
    Image.new("RGB", (8, 8), (70, 120, 170)).save(buffer, "JPEG", quality=95)
    jpeg = buffer.getvalue()
    reference = Image.open(BytesIO(jpeg)).convert("RGBA").tobytes()
    inline = base64.b64encode(jpeg).decode()
    for name, href in (("jpeg-resource", "../paint.jpg"), ("jpeg-inline", "data:image/jpeg;base64," + inline)):
        archive_path = OUT / f"{name}.ora"
        rendered = OUT / f"{name}.png"
        rendered.unlink(missing_ok=True)
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("mimetype", "image/openraster")
            archive.writestr("stack.xml", '<image version="0.0.6" w="8" h="8"><stack><layer src="data/svg/photo.svg"/></stack></image>')
            archive.writestr("data/svg/photo.svg", f'<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><image href="{href}" width="8" height="8"/></svg>')
            if name == "jpeg-resource":
                archive.writestr("data/paint.jpg", jpeg)
            archive.writestr("mergedimage.png", png(8, 8, 8, lambda x, y: (0, 0, 0, 0)))
            archive.writestr("Thumbnails/thumbnail.png", png(8, 8, 8, lambda x, y: (0, 0, 0, 0)))
        subprocess.run(["node", str(cli), "render", str(archive_path), str(rendered)], check=True)
        with Image.open(rendered) as actual:
            assert actual.size == (8, 8)
            assert max(abs(a-b) for a,b in zip(reference, actual.convert("RGBA").tobytes())) <= 1
    print("PASS: embedded and archived SVG JPEG match Pillow")


def check_nested_svg_image(cli):
    source = OUT / "nested-image-input.ora"
    edited = OUT / "nested-image-edited.ora"
    edited.unlink(missing_ok=True)
    resources = {
        "data/main.svg": b'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3" height="1"><image xlink:href="icons/sub.svg" width="2" height="1"/></svg>',
        "data/icons/sub.svg": b'<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"><style>@import "styles/paint.css";</style><rect class="color" width="1" height="1"/><image href="pixel.png" x="1" width="1" height="1"/></svg>',
        "data/icons/styles/paint.css": b".color { fill: #ff0000; }",
        "data/icons/pixel.png": png(1, 1, 8, lambda x, y: (0, 255, 0, 255)),
        "data/base.png": png(3, 1, 16, lambda x, y: BASE),
    }
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="3" h="1"><stack><layer name="Vector" src="data/main.svg"/><layer name="Raster" src="data/base.png"/></stack></image>')
        for name, data in resources.items():
            archive.writestr(name, data)
        archive.writestr("mergedimage.png", png(3, 1, 16, lambda x, y: BASE))
        archive.writestr("Thumbnails/thumbnail.png", png(3, 1, 8, lambda x, y: (0, 0, 255, 255)))
    subprocess.run(["node", str(cli), "edit", str(source), str(edited), str(OUT / "font-edits.json")], check=True)
    with zipfile.ZipFile(edited) as archive:
        for name, data in resources.items():
            if name != "data/base.png":
                assert archive.read(name) == data, name
        raster = ET.fromstring(archive.read("stack.xml")).find("./stack/layer[@name='Raster']")
        assert raster.get("x") == "1"
        assert decode_rgba(archive.read(raster.get("src"))) == (3, 1, 16, [BASE] * 3)
        assert decode_rgba(archive.read("mergedimage.png")) == (
            3, 1, 16, [(65535, 0, 0, 65535), (0, 65535, 0, 65535), BASE]
        )
    print("PASS: nested SVG image and its relative resources survive a mixed-depth edit")


def probe_krita(executable):
    from PIL import Image

    red, white, blue = (255, 0, 0, 255), (255, 255, 255, 255), (0, 0, 255, 255)
    preview = png(16, 8, 8, lambda x, y: blue)
    base = png(16, 8, 8, lambda x, y: white)
    with tempfile.TemporaryDirectory(prefix="moonora-krita-svg-") as tmp:
        for kind in ("png", "svg-path", "svg-text"):
            source = Path(tmp) / f"{kind}.ora"
            output = source.with_suffix(".png")
            top = "data/top.png" if kind == "png" else "data/art/text.svg"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("mimetype", "image/openraster")
                archive.writestr("stack.xml", f'<image version="0.0.6" w="16" h="8"><stack><layer name="Top" src="{top}"/><layer name="Base" src="data/base.png"/></stack></image>')
                archive.writestr("data/base.png", base)
                archive.writestr("mergedimage.png", preview)
                archive.writestr("Thumbnails/thumbnail.png", preview)
                if kind == "png":
                    archive.writestr(top, png(16, 8, 8, lambda x, y: red))
                elif kind == "svg-path":
                    archive.writestr(top, '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="8"><path fill="red" d="M0 0H16V8H0Z"/></svg>')
                else:
                    with zipfile.ZipFile(OUT / "font-input.ora") as original:
                        archive.writestr(top, original.read(top))
                        archive.writestr("data/font/测试.ttf", original.read("data/font/测试.ttf"))
            subprocess.run([str(executable.resolve()), "--nosplash", "--export",
                            "--export-filename", str(output), str(source)],
                           check=True, capture_output=True, timeout=30,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            with Image.open(output) as image:
                pixels = list(image.convert("RGBA").getdata())
            print(f"Krita {kind}: red={pixels.count(red)}, white={pixels.count(white)}, preview blue={pixels.count(blue)}")



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser-output", type=Path)
    parser.add_argument("--krita", type=Path, help="Probe vector-layer import in an independent Krita process")
    args = parser.parse_args()
    if args.browser_output:
        check_atlas(args.browser_output)
        return

    OUT.mkdir(parents=True, exist_ok=True)
    source, edited, output = (OUT / name for name in ("input.ora", "edited.ora", "rendered.png"))
    for dest in (edited, output):
        dest.unlink(missing_ok=True)
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="4" h="2"><stack><stack name="Group"><layer name="Vector" src="data/design/vector.svg"/></stack><layer name="Base" src="data/base.png"/></stack></image>')
        archive.writestr("data/design/vector.svg", SVG)
        archive.writestr("data/paint.css", CSS)
        archive.writestr("data/base.png", png(4, 2, 16, lambda x, y: BASE))
        archive.writestr("mergedimage.png", png(4, 2, 16, lambda x, y: (65535, 0, 0, 65535) if x == 0 else BASE))
        archive.writestr("Thumbnails/thumbnail.png", png(4, 2, 8, lambda x, y: (255, 0, 0, 255) if x == 0 else (39, 78, 117, 255)))
    changes = OUT / "edits.json"
    changes.write_text(json.dumps([{"path": [0, 0], "x": 2, "opacity": .5}]), encoding="utf-8")
    subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
    cli = ROOT / "_build/js/debug/build/cmd/main/main.js"
    subprocess.run(["node", str(cli), "edit", str(source), str(edited), str(changes)], check=True)
    subprocess.run(["node", str(cli), "render", str(edited), str(output)], check=True)
    # The isolated group stores round(0.5 * 65535) before it blends onto Base.
    a = 32768
    blend = tuple((front * a + back * (65535 - a) + 32767) // 65535
                  for front, back in zip((65535, 0, 0, 65535), BASE))
    with zipfile.ZipFile(edited) as archive:
        first = archive.infolist()[0]
        assert first.filename == "mimetype" and first.compress_type == zipfile.ZIP_STORED
        assert archive.read(first) == b"image/openraster"
        layer = ET.fromstring(archive.read("stack.xml")).find("./stack/stack/layer")
        assert layer.get("x") == "2"
        assert float(layer.get("opacity")) == .5
        assert layer.get("src") == "data/design/vector.svg" and archive.read(layer.get("src")) == SVG
        assert archive.read("data/paint.css") == CSS
        assert decode_rgba(archive.read("mergedimage.png")) == (4, 2, 16, [BASE, BASE, blend, BASE] * 2)
        assert archive.read("mergedimage.png") == output.read_bytes()
        thumbnail = archive.read("Thumbnails/thumbnail.png")
        assert thumbnail[24] == 8 and thumbnail[28] == 0
    for variant in (
        "font", "embedded-font", "font-spans", "font-stylesheet", "font-stylesheet-pi",
        "font-css-cascade", "font-centered-spans", "font-length-spacing", "font-length-glyphs",
        "font-svg-resource", "font-path", "font-path-resource", "font-position-list",
        "font-letter-spacing", "font-weight", "font-style", "font-alternate-sources", "font-relative-size",
    ):
        check_font_layer(cli, variant)
    check_default_font(cli)
    check_svg_jpeg(cli)
    check_nested_svg_image(cli)
    if args.krita:
        probe_krita(args.krita)
    check_atlas(ATLAS / "atlas-goal.ora")
    print("PASS: CLI edits a nested SVG layer, recomposes precise RGBA16, and preserves the vector source")


if __name__ == "__main__":
    main()
