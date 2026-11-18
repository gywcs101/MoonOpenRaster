"""Build an independent 16-bit ORA and verify edit/recompose/save at full precision."""
import argparse
from io import BytesIO
import json
from pathlib import Path
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "fixtures/gradient16.ora"
EDITS = ROOT / "fixtures/gradient16-edits.json"
OUT = ROOT / "_build/rgba16"
SIGNATURE = b"\x89PNG\r\n\x1a\n"
WIDTH, HEIGHT = 32, 20


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def background(x, y):
    return (20101 + x * 984, 17009 + y * 1555, 26461, 65535)


def light(x, y):
    return (33557, 41111 + x * 989, 51127 + y * 1047, 65535)


def composite(x, y, left, top, half):
    back = background(x, y)
    if left <= x < left + 12 and top <= y < top + 8:
        front = light(x - left, y - top)
        return tuple((a + b + 1) // 2 for a, b in zip(front, back)) if half else front
    return back


def png(w, h, bits, pixel, metadata=None):
    sample = ">4H" if bits == 16 else ">4B"
    rows = b"".join(b"\0" + b"".join(struct.pack(sample, *pixel(x, y)) for x in range(w)) for y in range(h))
    head = struct.pack(">IIBBBBB", w, h, bits, 6, 0, 0, 0)
    color = chunk(b"sRGB", b"\0") if metadata is None else metadata
    return SIGNATURE + chunk(b"IHDR", head) + color + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def fixture():
    archive = BytesIO()
    merged = lambda x, y: composite(x, y, 5, 4, False)
    with zipfile.ZipFile(archive, "w") as file:
        file.writestr("mimetype", "image/openraster")
        file.writestr("stack.xml", '<image version="0.0.6" w="32" h="20" xres="75" yres="75" name="Gradient"><stack><stack name="Gradient group" isolation="isolate"><layer name="Light" x="5" y="4" src="data/light.png"/></stack><layer name="Base" src="data/base.png"/></stack></image>')
        file.writestr("data/light.png", png(12, 8, 16, light))
        file.writestr("data/base.png", png(WIDTH, HEIGHT, 16, background))
        file.writestr("mergedimage.png", png(WIDTH, HEIGHT, 16, merged))
        file.writestr("Thumbnails/thumbnail.png", png(WIDTH, HEIGHT, 8, lambda x, y: tuple((c + 128) // 257 for c in merged(x, y))))
    return archive.getvalue()


def decode_rgba(data):
    """Independent non-interlaced RGB(A) PNG reader that keeps original sample values."""
    assert data[:8] == SIGNATURE
    at, idat = 8, bytearray()
    while at < len(data):
        length, kind = struct.unpack_from(">I4s", data, at)
        payload = data[at + 8: at + 8 + length]
        assert zlib.crc32(kind + payload) == struct.unpack_from(">I", data, at + 8 + length)[0]
        at += 12 + length
        if kind == b"IHDR":
            w, h, bits, color, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            assert not interlace and color in (2, 6) and bits in (8, 16)
        if kind == b"IDAT":
            idat.extend(payload)
        if kind == b"IEND":
            break
    channels = 4 if color == 6 else 3
    bpp = channels * bits // 8
    stride = w * bpp
    raw = zlib.decompress(idat)
    assert len(raw) == (stride + 1) * h
    previous = bytearray(stride)
    pixels = []
    for y in range(h):
        start = y * (stride + 1)
        mode = raw[start]
        assert mode in range(5)
        row = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left, above = row[x - bpp] if x >= bpp else 0, previous[x]
            corner = previous[x - bpp] if x >= bpp else 0
            if mode == 4:
                p = left + above - corner
                predict = min((left, above, corner), key=lambda v: abs(p - v))
            else:
                predict = (0, left, above, (left + above) // 2)[mode]
            row[x] = (row[x] + predict) & 255
        for samples in struct.iter_unpack(">" + ("H" if bits == 16 else "B") * channels, row):
            pixels.append(samples + ((1 << bits) - 1,) if channels == 3 else samples)
        previous = row
    return w, h, bits, pixels


def verify_saved(path):
    with zipfile.ZipFile(path) as file, zipfile.ZipFile(FIXTURE) as source:
        assert file.infolist()[0].filename == "mimetype" and file.infolist()[0].compress_type == zipfile.ZIP_STORED
        tree = ET.fromstring(file.read("stack.xml"))
        assert tree.attrib["version"] == "0.0.6"
        assert (tree.attrib["xres"], tree.attrib["yres"]) == ("75", "75")
        group = tree.find("./stack/stack")
        assert group.attrib["name"] == "Gradient group"
        node = group.find("layer")
        assert (node.attrib["name"], int(node.attrib["x"]), int(node.attrib["y"]), float(node.attrib["opacity"])) == ("Light", 9, 6, .5)
        base = tree.find("./stack/layer")
        for node, origin in ((node, "light"), (base, "base")):
            layer = decode_rgba(file.read(node.attrib["src"]))
            assert layer == decode_rgba(source.read("data/" + origin + ".png"))
            assert any(value % 257 for pixel in layer[3] for value in pixel[:3])
        png_data = file.read("mergedimage.png")
        w, h, bits, samples = decode_rgba(png_data)
        assert (w, h, bits) == (WIDTH, HEIGHT, 16)
        expected = [composite(x, y, 9, 6, True) for y in range(h) for x in range(w)]
        assert max(abs(a - b) for p, q in zip(samples, expected) for a, b in zip(p, q)) <= 1
        assert png_data != source.read("mergedimage.png")
        thumb = file.read("Thumbnails/thumbnail.png")
        assert (thumb[24], thumb[28]) == (8, 0)
        assert decode_rgba(thumb) == (w, h, 8, [tuple((c + 128) // 257 for c in p) for p in samples])
    return png_data


def check_input_variants(cli):
    """Check color markers, low-bit palette/gray normalization and error boundaries."""
    palette = (
        SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 1, 3, 0, 0, 0))
        + chunk(b"PLTE", bytes([0, 0, 0, 19, 29, 39]))
        + chunk(b"tRNS", bytes([255, 101]))
        + chunk(b"IDAT", zlib.compress(bytes([0, 128]))) + chunk(b"IEND", b"")
    )
    chroma = struct.pack(">8I", 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000)
    srgb = chunk(b"gAMA", struct.pack(">I", 45455)) + chunk(b"cHRM", chroma)
    narrow = (19, 29, 39, 101)
    wide = (10001, 20002, 30003, 65535)
    cases = [
        (palette, 8, narrow, None),
        (png(1, 1, 16, lambda x, y: wide, srgb), 16, wide, None),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"gAMA", struct.pack(">I", 100000))), 16, wide, "Non-sRGB PNG gamma"),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"iCCP", b"sRGB-elle-V2-srgbtrc.icc\0\0" + zlib.compress(b"not the approved profile"))), 16, wide, "ICC-profiled PNG"),
    ]
    for index, (layer, bits, expected, error) in enumerate(cases):
        case = OUT / f"variant-{index}.ora"
        output = OUT / f"variant-{index}.png"
        output.unlink(missing_ok=True)
        with zipfile.ZipFile(case, "w") as file:
            file.writestr("mimetype", "image/openraster")
            file.writestr("stack.xml", '<image version="0.0.6" w="1" h="1"><stack><layer src="data/layer.png"/></stack></image>')
            file.writestr("data/layer.png", layer)
            file.writestr("mergedimage.png", png(1, 1, 8, lambda x, y: (0, 0, 0, 255)))
        result = subprocess.run(["node", str(cli), "render", str(case), str(output)], capture_output=True, text=True)
        if error:
            assert result.returncode != 0 and error in result.stderr, result.stderr
            assert not output.exists()
        else:
            assert result.returncode == 0, result.stderr
            assert decode_rgba(output.read_bytes()) == (1, 1, bits, [expected])
    print("PASS: palette transparency, canonical sRGB markers, linear gamma and untrusted ICC")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate-fixture", action="store_true")
    parser.add_argument("--krita", type=Path)
    parser.add_argument("--krita-profile", type=Path, help="Krita’s bundled sRGB-elle-V2-srgbtrc.icc for noninteractive import")
    parser.add_argument("--browser-output", type=Path)
    args = parser.parse_args()
    if args.generate_fixture:
        FIXTURE.write_bytes(fixture())
        return
    if args.browser_output:
        verify_saved(args.browser_output)
        print("PASS: real browser ORA has independent 16-bit pixel and structure parity")
        return
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["moon", "build", "--target", "js", "--deny-warn"], cwd=ROOT, check=True)
    cli = ROOT / "_build/js/debug/build/cmd/main/main.js"
    result = OUT / "edited.ora"
    result.unlink(missing_ok=True)
    subprocess.run(["node", str(cli), "edit", str(FIXTURE), str(result), str(EDITS)], check=True)
    (OUT / "edited.png").write_bytes(verify_saved(result))
    rerendered = OUT / "reopened.png"
    rerendered.unlink(missing_ok=True)
    subprocess.run(["node", str(cli), "render", str(result), str(rerendered)], check=True)
    assert rerendered.read_bytes() == (OUT / "edited.png").read_bytes()
    print("PASS: exact source samples, 16-bit independent composition, fresh thumbnail and CLI reopen", flush=True)
    check_input_variants(cli)
    if args.krita:
        from PIL import Image
        outputs = {}
        interop_input = result
        if args.krita_profile:
            # Krita prompts when opening a 16-bit PNG without an embedded ICC.
            # Add ICC only to temporary interoperability copies. IDAT stays intact.
            profile = args.krita_profile.read_bytes()
            icc = chunk(b"iCCP", b"sRGB-elle-V2-srgbtrc.icc\0\0" + zlib.compress(profile))
            interop_input = OUT / "edited-krita-import.ora"
            with zipfile.ZipFile(result) as source, zipfile.ZipFile(interop_input, "w") as dest:
                for name in source.namelist():
                    payload = source.read(name)
                    if name.endswith(".png") and payload[24] == 16:
                        at = 33
                        while payload[at + 4:at + 8] != b"IDAT":
                            size = struct.unpack_from(">I", payload, at)[0]
                            if payload[at + 4:at + 8] == b"sRGB":
                                payload = payload[:at] + payload[at + 12 + size:]
                            else:
                                at += 12 + size
                        payload = payload[:33] + icc + payload[33:]
                        assert decode_rgba(payload) == decode_rgba(source.read(name))
                    dest.writestr(name, payload)
            tagged_result = OUT / "tagged-render.png"
            tagged_result.unlink(missing_ok=True)
            subprocess.run(["node", str(cli), "render", str(interop_input), str(tagged_result)], check=True)
            assert decode_rgba(tagged_result.read_bytes()) == decode_rgba((OUT / "edited.png").read_bytes())
        for suffix in ("png", "ora"):
            output = OUT / ("krita-reopened." + suffix)
            output.unlink(missing_ok=True)
            subprocess.run([str(args.krita.resolve()), "--nosplash", "--export", "--export-filename", str(output), str(interop_input)], check=True, capture_output=True, timeout=60)
            outputs[suffix] = output
        a = Image.open(BytesIO((OUT / "edited.png").read_bytes())).convert("RGBA")
        b = Image.open(outputs["png"]).convert("RGBA")
        assert a.size == b.size
        delta = max(abs(x - y) for x, y in zip(a.tobytes(), b.tobytes()))
        assert delta <= 2, delta
        with zipfile.ZipFile(outputs["ora"]) as file:
            group = ET.fromstring(file.read("stack.xml")).find("./stack/stack")
            layer = group.find("layer")
            assert group.attrib["name"] == "Gradient group" and layer.attrib["name"] == "Light"
            assert (layer.attrib["x"], layer.attrib["y"]) == ("9", "6")
            assert abs(float(layer.attrib["opacity"]) - .5) <= 1 / 255
            depths = [file.read(i)[24] for i in file.namelist() if i.startswith("data/") and i.endswith(".png")]
        evidence = {"krita": "5.3.4", "display_max_8bit_channel_error": delta, "ora_resave_layer_depths": depths}
        (OUT / "krita-results.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        print("PASS: live Krita reopen and independent display comparison:", evidence)


if __name__ == "__main__":
    main()
