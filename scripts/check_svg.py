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


def with_vertical_substitution(font):
    # Single OpenType vert substitution from original glyph 2 (中) to glyph 1
    # (the smaller square). This is the same table used in the HarfBuzz probe.
    gsub = bytes.fromhex(
        "00010000000a001e002c000144464c540008000400000000ffff000100000001"
        "76657274000800000001000000010004000100000001000800010006ffff000100010002"
    )
    count = struct.unpack_from(">H", font, 4)[0]
    tables = [(tag, font[start:start + length]) for tag, _, start, length in struct.iter_unpack(">4sIII", font[12:12 + count * 16])]
    tables.append((b"GSUB", gsub))
    tables.sort()
    count = len(tables)
    power = count.bit_length() - 1
    result = bytearray(struct.pack(">4sHHHH", font[:4], count, 16 << power, power, count * 16 - (16 << power)))
    data = bytearray()
    offset = 12 + count * 16
    for tag, table in tables:
        padded = table + bytes(-len(table) % 4)
        checksum = sum(word for (word,) in struct.iter_unpack(">I", padded)) & 0xFFFFFFFF
        result += struct.pack(">4sIII", tag, checksum, offset + len(data), len(table))
        data += padded
    return bytes(result + data)


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
    percentage_position = variant == "font-percentage-position"
    external_outline_font = variant == "font-svg-outline-resource"
    outline_font = variant == "font-svg-outline" or external_outline_font
    unavailable_primary = variant == "font-unavailable-primary"
    fallback_all = variant == "font-glyph-fallback-all"
    fallback = variant == "font-glyph-fallback" or fallback_all
    bidi_embed = variant == "font-rtl-embed"
    bidi_spans = variant == "font-rtl-spans" or bidi_embed
    right_to_left = variant == "font-rtl" or bidi_spans
    vertical_substitution = variant == "font-vertical-substitution"
    vertical_spans = variant == "font-vertical-spans"
    vertical_mixed = variant == "font-vertical-mixed" or vertical_spans
    vertical = variant in ("font-vertical", "font-vertical-centered") or vertical_mixed or vertical_substitution
    centered_vertical = variant == "font-vertical-centered"
    external_tref = variant == "font-tref-resource"
    text_reference = variant == "font-tref" or external_tref
    external = variant == "font-svg-resource"
    path_external = variant == "font-path-resource"
    path_text = variant == "font-path" or path_external
    positions = variant == "font-position-list"
    stem = variant
    source = OUT / f"{stem}-input.ora"
    edited = OUT / f"{stem}-edited.ora"
    edited.unlink(missing_ok=True)
    font = (ROOT / "fixtures/ora-test.ttf").read_bytes()
    latin_font = font
    if vertical_substitution:
        font = with_vertical_substitution(font)
    if right_to_left:
        # Keep the authored outlines and advances. Map them to two Hebrew letters.
        modified = bytearray(font)
        count = struct.unpack_from(">H", font, 4)[0]
        cmap = next(offset for tag, _, offset, _ in struct.iter_unpack(
            ">4sIII", font[12:12 + count * 16]) if tag == b"cmap")
        table = cmap + struct.unpack_from(">I", font, cmap + 8)[0]
        form, _, _, double_count = struct.unpack_from(">HHHH", font, table)
        assert form == 4 and double_count == 6
        ends = table + 14
        starts = ends + double_count + 2
        deltas = starts + double_count
        for index, codepoint in enumerate((0x05D0, 0x05D1)):
            struct.pack_into(">H", modified, ends + index * 2, codepoint)
            struct.pack_into(">H", modified, starts + index * 2, codepoint)
            struct.pack_into(">h", modified, deltas + index * 2, index + 1 - codepoint)
        font = bytes(modified)
    if fallback:
        primary = bytearray(font)
        count = struct.unpack_from(">H", font, 4)[0]
        font_tables = {tag: offset for tag, _, offset, _ in struct.iter_unpack(">4sIII", font[12:12 + count * 16])}
        cmap = font_tables[b"cmap"]
        table = cmap + struct.unpack_from(">I", font, cmap + 8)[0]
        struct.pack_into(">H", primary, table + 16, 0x05D1)
        struct.pack_into(">H", primary, table + 24, 0x05D1)
        struct.pack_into(">h", primary, table + 30, 2 - 0x05D1)
        struct.pack_into(">H", primary, font_tables[b"hmtx"], 1500)
    uri = "data:font/ttf;base64," + base64.b64encode(font).decode() if embedded else "../font/%E6%B5%8B%E8%AF%95.ttf"
    face = f'@font-face {{ font-family: OraTest; src: url("{uri}"); }}'
    if multiple_sources:
        face = f'@font-face {{ font-family: OraTest; src: local("Uninstalled"), URL("../font/unsupported.woff"), url("{uri}") format("truetype"); }}'
    if bidi_spans:
        face += '@font-face { font-family: Latin; src: url("../font/latin.ttf"); }'
    if fallback:
        face += '@font-face { font-family: Limited; src: url("../font/limited.ttf"); }'
    if unavailable_primary:
        face += '@font-face { font-family: Absent; src: url("../font/absent.ttf"); }'
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
    if fallback_all:
        text = "中"
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
    if unavailable_primary:
        font_attributes = 'font-family="Absent, OraTest" font-size="8" fill="red"'
    if fallback:
        font_attributes = 'font-family="Limited, OraTest" font-size="8" fill="red"'
    parent_attrs = ""
    if relative_size:
        position_attrs = 'x="0" y="1em"'
        font_attributes = 'font-family="OraTest" font-size="50%" fill="red"'
        parent_attrs = ' font-size="16px"'
        text = 'A<tspan font-size="1em">中</tspan>'
    if percentage_position:
        position_attrs = 'x="0%" y="100%"'
        parent_attrs = ' viewBox="0 0 8 4"'
        font_attributes = 'font-family="OraTest" font-size="4" fill="red"'
    if right_to_left:
        position_attrs = 'x="16" y="8" direction="rtl" xml:lang="he"'
        text = "אב"
        if bidi_spans:
            font_attributes = 'font-family="OraTest" font-size="4" fill="red"'
            span_direction = ' direction="ltr" unicode-bidi="embed"' if bidi_embed else ""
            text = f'אב<tspan font-family="Latin" fill="blue"{span_direction}>A</tspan>'
    if vertical:
        position_attrs = 'x="5" y="4" writing-mode="tb-rl" text-anchor="middle"' if centered_vertical else 'x="5" y="0" writing-mode="tb" glyph-orientation-vertical="0"'
        font_attributes = 'font-family="OraTest" font-size="4" fill="red"'
        text = "中中"
        if vertical_mixed:
            text = "A中"
            position_attrs = 'x="5" y="0" writing-mode="tb"'
        if vertical_spans:
            text = "A<tspan>中</tspan>"
            position_attrs = 'x="5" y="4" writing-mode="tb" text-anchor="middle"'
    if text_reference:
        definition = '<defs><text id="fragment" font-family="OraTest">中</text></defs>'
        referenced_text = f'<svg xmlns="http://www.w3.org/2000/svg">{definition}</svg>'.encode()
        text = 'A<tref href="#fragment"/>'
        if external_tref:
            definition = ""
            text = text.replace("#fragment", "../word/label.svg#fragment")
    if outline_font:
        inline_style = (
            '<defs><font id="outline" horiz-adv-x="1000"><font-face font-family="OraTest" units-per-em="1000"/>'
            '<glyph unicode="A" glyph-name="latin" d="M0 0 H500 V500 H0Z"/>'
            '<glyph unicode="中" glyph-name="han"><path d="M0 0 H750 V750 H0Z"/></glyph>'
            '<hkern g1="latin" u2="中" k="125"/></font></defs>'
        )
        if external_outline_font:
            outline_resource = f'<svg xmlns="http://www.w3.org/2000/svg">{inline_style}</svg>'.encode()
            inline_style = '<style>@font-face { font-family: OraTest; src: url("../font/outlines.svg#outline"); }</style>'
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
        if vertical_substitution:
            return 3 <= x < 5 and y % 4 >= 2
        if fallback_all:
            return x < 6 and y >= 2
        if bidi_spans:
            return (8 <= x < 11 and y >= 5) or (12 <= x < 14 and y >= 6)
        if fallback:
            return (x < 4 and y >= 4) or (x >= 12 and y >= 2)
        if stretched:
            return (x < 6 and y >= 4) or (x >= 12 and y >= 2)
        if spacing or letter_spacing or weighted or slanted:
            return (x < 4 and y >= 4) or (x >= 12 and y >= 2)
        if outline_font:
            return (x < 4 and y >= 4) or (7 <= x < 13 and y >= 2)
        if right_to_left:
            return (x < 6 and y >= 2) or (8 <= x < 12 and y >= 4)
        if vertical_mixed:
            return (3 <= x < 5 and y < 2) or (3 <= x < 6 and y >= 5)
        if vertical:
            return 3 <= x < 6 and y % 4 != 0
        return (x < 4 and y >= 4) or (8 <= x < 14 and y >= 2)

    def ink(x, y, background):
        if bidi_spans and 4 <= x < 6 and y >= 6:
            return (0, 0, 65535, 65535)
        return red if glyph_ink(x, y) else background

    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="16" h="8" xres="96"><stack><layer name="Text" src="data/art/text.svg"/><layer name="Raster" src="data/base.png"/></stack></image>')
        archive.writestr("data/art/text.svg", svg)
        if external:
            archive.writestr("data/word/source.svg", external_svg)
        if path_external:
            archive.writestr("data/paths/layout.svg", path_resource)
        if external_outline_font:
            archive.writestr("data/font/outlines.svg", outline_resource)
        if external_tref:
            archive.writestr("data/word/label.svg", referenced_text)
        if not embedded and not outline_font:
            archive.writestr("data/font/测试.ttf", font)
        if fallback:
            archive.writestr("data/font/limited.ttf", primary)
        if bidi_spans:
            archive.writestr("data/font/latin.ttf", latin_font)
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
        archive.writestr("mergedimage.png", png(16, 8, 16, lambda x, y: ink(x, y, BASE)))
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
        if external_outline_font:
            assert archive.read("data/font/outlines.svg") == outline_resource
        if external_tref:
            assert archive.read("data/word/label.svg") == referenced_text
        if not embedded and not outline_font:
            assert archive.read("data/font/测试.ttf") == font
            assert archive.getinfo("data/font/测试.ttf").flag_bits & 0x800
        if fallback:
            assert archive.read("data/font/limited.ttf") == primary
        if bidi_spans:
            assert archive.read("data/font/latin.ttf") == latin_font
        if imported:
            assert archive.read("data/styles/level/index.css") == b"@import 'font.css';"
            assert archive.read("data/styles/level/font.css").decode() == face.replace("../font/", "../../font/")
        root = ET.fromstring(archive.read("stack.xml"))
        assert (root.get("xres"), root.get("yres")) == ("96", "72")
        assert root.find("./stack/layer[@name='Raster']").get("x") == "1"
        expected = [ink(x, y, BASE if x else (0, 0, 0, 0))
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


def check_nested_svg_image(cli, *, views=False):
    variant = "nested-image-views" if views else "nested-image"
    source = OUT / f"{variant}-input.ora"
    edited = OUT / f"{variant}-edited.ora"
    edited.unlink(missing_ok=True)
    resources = {
        "data/main.svg": b'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3" height="1"><image xlink:href="icons/sub.svg" width="2" height="1"/></svg>',
        "data/icons/sub.svg": b'<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"><style>@import "styles/paint.css";</style><rect class="color" width="1" height="1"/><image href="pixel.png" x="1" width="1" height="1"/></svg>',
        "data/icons/styles/paint.css": b".color { fill: #ff0000; }",
        "data/icons/pixel.png": png(1, 1, 8, lambda x, y: (0, 255, 0, 255)),
        "data/base.png": png(3, 1, 16, lambda x, y: BASE),
    }
    if views:
        resources["data/main.svg"] = b'<svg xmlns="http://www.w3.org/2000/svg" width="3" height="1"><image href="icons/sub.svg#left" width="1" height="1"/><image href="icons/sub.svg#svgView(viewBox(1,0,1,1))" x="1" width="1" height="1"/></svg>'
        resources["data/icons/sub.svg"] = (
            b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" viewBox="0 0 2 1">'
            b'<view id="left" viewBox="0 0 1 1"/><style>@import "styles/paint.css";</style>'
            b'<defs><filter id="ink" filterUnits="userSpaceOnUse" x="0" y="0" width="1" height="1">'
            b'<feFlood result="tone"/><feComposite in="tone" in2="SourceGraphic" operator="in"/>'
            b'</filter></defs><text font-family="OraTest" font-size="2" x="0" y="1" filter="url(#ink)">A</text>'
            b'<image href="pixel.png" x="1" width="1" height="1"/></svg>'
        )
        resources["data/icons/styles/paint.css"] = (
            b'@font-face { font-family: OraTest; src: url("../../font/press.ttf"); } '
            b'filter { color: #ff0000; } filter > feFlood { flood-color: currentColor; }'
        )
        resources["data/font/press.ttf"] = (ROOT / "fixtures/ora-test.ttf").read_bytes()
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="3" h="1"><stack><layer name="Vector" src="data/main.svg"/><layer name="Raster" src="data/base.png"/></stack></image>')
        for name, data in resources.items():
            archive.writestr(name, data)
        archive.writestr("mergedimage.png", png(3, 1, 16, lambda x, y: BASE))
        archive.writestr("Thumbnails/thumbnail.png", png(3, 1, 8, lambda x, y: (0, 0, 255, 255)))
    raster_edits = OUT / "font-edits.json"
    vector_edits = OUT / "view-vector-edits.json"
    vector_edits.write_text('[{"path":[0],"x":1,"opacity":0.5}]', encoding="utf-8")
    results = [(edited, raster_edits, [(65535, 0, 0, 65535), (0, 65535, 0, 65535), BASE])]
    if views:
        results.append((OUT / f"{variant}-vector-edited.ora", vector_edits, [
            BASE,
            (37768, 10001, 15002, 65535),
            (5001, 42769, 15002, 65535),
        ]))
    for output, edits, pixels in results:
        output.unlink(missing_ok=True)
        subprocess.run(["node", str(cli), "edit", str(source), str(output), str(edits)], check=True)
        with zipfile.ZipFile(output) as archive:
            for name, data in resources.items():
                if name != "data/base.png":
                    assert archive.read(name) == data, name
            stack = ET.fromstring(archive.read("stack.xml")).find("stack")
            assert [node.get("name") for node in stack] == ["Vector", "Raster"]
            if edits == vector_edits:
                assert stack[0].get("x") == "1" and float(stack[0].get("opacity")) == 0.5
            else:
                assert stack[1].get("x") == "1"
            assert decode_rgba(archive.read(stack[1].get("src"))) == (3, 1, 16, [BASE] * 3)
            assert decode_rgba(archive.read("mergedimage.png")) == (3, 1, 16, pixels)
    print(f"PASS: {variant} and its relative resources survive a mixed-depth edit")



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
        "font-letter-spacing", "font-weight", "font-style", "font-alternate-sources",
        "font-relative-size", "font-percentage-position", "font-svg-outline", "font-svg-outline-resource", "font-rtl",
        "font-tref", "font-tref-resource",
        "font-vertical", "font-vertical-centered", "font-vertical-mixed", "font-vertical-spans", "font-vertical-substitution", "font-rtl-spans", "font-rtl-embed", "font-glyph-fallback", "font-glyph-fallback-all", "font-unavailable-primary",
    ):
        check_font_layer(cli, variant)
    check_default_font(cli)
    check_svg_jpeg(cli)
    check_nested_svg_image(cli)
    check_nested_svg_image(cli, views=True)
    if args.krita:
        probe_krita(args.krita)
    check_atlas(ATLAS / "atlas-goal.ora")
    print("PASS: CLI edits a nested SVG layer, recomposes precise RGBA16, and preserves the vector source")


if __name__ == "__main__":
    main()
