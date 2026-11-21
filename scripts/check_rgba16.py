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
    def linear_to_srgb(value):
        value /= 65535
        encoded = value * 12.92 if value <= .0031308 else 1.055 * value ** (1 / 2.4) - .055
        return round(encoded * 65535)

    linear = tuple(linear_to_srgb(value) for value in wide[:3]) + (wide[3],)
    cases = [
        (palette, 8, narrow, None),
        (png(1, 1, 16, lambda x, y: wide, srgb), 16, wide, None),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"gAMA", struct.pack(">I", 100000))), 16, linear, None),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"cICP", bytes([1, 8, 0, 1]))), 16, linear, None),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"cICP", bytes([1, 13, 0, 1])) + chunk(b"gAMA", struct.pack(">I", 100000))), 16, wide, None),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"cICP", bytes([9, 16, 0, 1]))), 16, wide, "cICP transfer"),
        (png(1, 1, 16, lambda x, y: wide, chunk(b"iCCP", b"sRGB-elle-V2-srgbtrc.icc\0\0" + zlib.compress(b"not the approved profile"))), 16, wide, "ICC-profiled image"),
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

def check_float_icc_rgba16(cli, profile):
    colors = [(25103, 31309, 46011, 52031), (50003, 34019, 14011, 63029), (10001, 18003, 26005, 65535)]
    # LittleCMS 2.16: TYPE_RGBA_16, standard sRGB destination, media-relative
    # colorimetric intent, original alpha. Keep the value prior to conversion
    # as a separate byte check so an 8-bit round trip cannot pass.
    reference = [(41723, 47686, 56877, 52031), (60020, 48854, 30091, 63029), (25604, 37465, 44103, 65535)]
    layer = png(3, 1, 16, lambda x, y: colors[x], chunk(b"iCCP", b"Float ICC\0\0" + zlib.compress(profile)))
    source = OUT / "mpet-rgba16.ora"
    output = OUT / "mpet-rgba16-edited.ora"
    output.unlink(missing_ok=True)
    pixels = [*reference, (0, 0, 0, 0)]
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", '<image version="0.0.6" w="4" h="1"><stack><layer name="Profiled" src="data/input.png"/></stack></image>')
        archive.writestr("data/input.png", layer)
        archive.writestr("mergedimage.png", png(4, 1, 16, lambda x, y: pixels[x]))
        archive.writestr("Thumbnails/thumbnail.png", png(4, 1, 8, lambda x, y: tuple((c + 128) // 257 for c in pixels[x])))
    subprocess.run(["node", str(cli), "edit", str(source), str(output), str(OUT / "icc-edit.json")], check=True)
    with zipfile.ZipFile(output) as archive:
        resource = ET.fromstring(archive.read("stack.xml")).find("./stack/layer")
        assert resource.get("x") == "1" and archive.read(resource.get("src")) == layer
        width, height, bits, rendered = decode_rgba(archive.read("mergedimage.png"))
        assert (width, height, bits) == (4, 1, 16)
        assert rendered[0] == (0, 0, 0, 0)
        maximum = max(abs(a - b) for actual, expected in zip(rendered[1:], reference) for a, b in zip(actual, expected))
        assert maximum <= 8 and [value[3] for value in rendered[1:]] == [value[3] for value in colors], maximum
    print(f"PASS: original RGBA16 ICC layer retained; maximum channel difference against LittleCMS 2.16: {maximum}")


def check_icc_profiles(cli):
    from io import BytesIO
    from PIL import Image, ImageCms

    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))
    base = srgb.tobytes()
    count = struct.unpack_from(">I", base, 128)[0]
    tags = {}
    for tag, offset, size in struct.iter_unpack(">4sII", base[132:132 + count * 12]):
        tags[tag] = base[offset:offset + size]
    # Relative D50 colorants for a synthetic wide RGB profile. Its name is
    # immaterial. LittleCMS reads the actual matrix and tone curve tags.
    wide_rgb = {
        b"rXYZ": (0.515102, 0.241182, -0.00104941),
        b"gXYZ": (0.291965, 0.692236, 0.0418818),
        b"bXYZ": (0.157153, 0.0665819, 0.784378),
    }
    for key, xyz in wide_rgb.items():
        tags[key] = b"XYZ " + bytes(4) + struct.pack(">3i", *(round(v * 65536) for v in xyz))

    def build_profile(tags, pcs=b"XYZ ", legacy=False):
        table = bytearray(struct.pack(">I", len(tags)))
        data = bytearray()
        offset = 132 + 12 * len(tags)
        for tag, payload in tags.items():
            table += struct.pack(">4sII", tag, offset + len(data), len(payload))
            data += payload + bytes(-len(payload) % 4)
        header = bytearray(base[:128])
        struct.pack_into(">I", header, 0, len(header) + len(table) + len(data))
        header[20:24] = pcs
        if legacy:
            header[8:12] = bytes.fromhex("02100000")
        header[84:100] = bytes(16)
        return bytes(header + table + data)

    values = [(70, 120, 170, 200), (230, 170, 85, 128), (18, 23, 41, 255)]
    image = Image.new("RGBA", (len(values), 1))
    image.putdata(values)
    curves = {
        "parametric": tags[b"rTRC"],
        "gamma": b"curv" + bytes(4) + struct.pack(">IH", 1, 512),
        "sampled": b"curv" + bytes(4) + struct.pack(">I3H", 3, 0, 16384, 65535),
    }
    p3_chroma = struct.pack(">8I", 31270, 32900, 68000, 32000, 26500, 69000, 15000, 6000)
    matrix_cases = [
        *(("icc-" + name, name, b"") for name in curves),
        ("cicp-p3", "parametric", chunk(b"cICP", bytes([12, 13, 0, 1]))),
        ("chrm-p3", "gamma", chunk(b"cHRM", p3_chroma) + chunk(b"gAMA", struct.pack(">I", 50000))),
    ]
    cases = []
    for variant, curve_name, extra in matrix_cases:
        for channel in (b"rTRC", b"gTRC", b"bTRC"):
            tags[channel] = curves[curve_name]
        cases.append((variant, build_profile(tags), extra))

    identity = struct.pack(">9i", 65536, 0, 0, 0, 65536, 0, 0, 0, 65536)
    xyz_samples = bytearray()
    lab_samples = bytearray()
    for r in range(2):
        for g in range(2):
            for b in range(2):
                xyz = [sum(v * wide_rgb[tag][axis] for v, tag in zip((r,g,b), wide_rgb))
                       for axis in range(3)]
                xyz_samples += struct.pack(">3H", *(round(max(0,v)*32768) for v in xyz))
                lab_samples += bytes((round(255*(r+g+b)/3),128,128))
    ramp = struct.pack(">HH", 0, 65535) * 3
    tables = (
        ("lut16-xyz", b"XYZ ", b"mft2" + bytes(4) + bytes((3,3,2,0)) + identity
         + struct.pack(">HH",2,2) + ramp + xyz_samples + ramp),
        ("lut8-lab", b"Lab ", b"mft1" + bytes(4) + bytes((3,3,2,0)) + identity
         + bytes(range(256))*3 + lab_samples + bytes(range(256))*3),
    )
    for name, pcs, payload in tables:
        lookup_tags = {key: value for key,value in tags.items()
                       if key not in (b"rXYZ",b"gXYZ",b"bXYZ",b"rTRC",b"gTRC",b"bTRC")}
        lookup_tags[b"A2B0"] = payload
        lookup_tags[b"A2B1"] = payload
        cases.append((name, build_profile(lookup_tags, pcs=pcs, legacy=True), b""))

    # ICC v4 curve, CLUT and matrix pipeline with unequal grid extents.
    identity_curve = b"curv" + bytes(8)
    stages = (
        identity_curve * 3,
        identity + struct.pack(">3i", 300, 0, 0),
        identity_curve * 3,
        bytes((2, 3, 2)) + bytes(13) + b"\x02\0\0\0",
        identity_curve * 3,
    )
    points = bytearray()
    for r in (0, 1):
        for g in (0, .5, 1):
            for b in (0, 1):
                xyz = [sum(v * wide_rgb[tag][axis] for v, tag in zip((r,g,b), wide_rgb))
                       for axis in range(3)]
                points += struct.pack(">3H", *(round(max(0,v)*32768) for v in xyz))
    stages = (*stages[:3], stages[3] + points, stages[4])
    offsets = [32]
    for stage in stages[:-1]:
        offsets.append(offsets[-1]+len(stage))
    payload = b"mAB " + bytes(4) + bytes((3,3,0,0)) + struct.pack(">5I", *offsets) + b"".join(stages)
    lookup_tags[b"A2B0"] = payload
    lookup_tags[b"A2B1"] = payload
    cases.append(("mab-xyz", build_profile(lookup_tags), b""))
    # A floating-point affine RGB-to-XYZ transform with a nonzero offset.
    matrix = [wide_rgb[tag][axis] for axis in range(3) for tag in wide_rgb]
    stage = b"matf" + bytes(4) + struct.pack(">HH12f", 3, 3, *matrix, .003, .005, 0)
    mpe = b"mpet" + bytes(4) + struct.pack(">HHIII", 3, 3, 1, 24, len(stage)) + stage
    matrix_profile = build_profile({**tags, b"D2B1": mpe})
    cases.append(("mpet-xyz", matrix_profile, b""))
    future = mpe[:24] + b"test" + stage[4:]
    cases.append(("mpet-fallback", build_profile({**tags, b"D2B1": future}), b""))
    cases.append(("mpet-other-intent", build_profile({**tags, b"D2B2": mpe}), b""))
    points = [
        sum(v * wide_rgb[tag][axis] for v, tag in zip((r, g, b), wide_rgb))
        for r in (0, 1) for g in (0, .5, 1) for b in (0, 1) for axis in range(3)
    ]
    clut = b"clut" + bytes(4) + struct.pack(">HH", 3, 3) + bytes((2, 3, 2)) + bytes(13)
    clut += struct.pack(f">{len(points)}f", *points)
    adjust = b"matf" + bytes(4) + struct.pack(">HH12f", 3, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1, .003, .005, 0)
    mpe_clut = b"mpet" + bytes(4) + struct.pack(">HHIIIII", 3, 3, 2, 32, len(clut), 32 + len(clut), len(adjust))
    cases.append(("mpet-clut", build_profile({**tags, b"D2B1": mpe_clut + clut + adjust}), b""))
    def formula(kind, *params):
        return b"parf" + bytes(4) + struct.pack(">HH", kind, 0) + struct.pack(f">{len(params)}f", *params)

    identity = formula(0, 1, 1, 0, 0)
    sampled = b"samf" + bytes(4) + struct.pack(">I2f", 2, .3, 1)
    curve_header = b"curf" + bytes(4)
    segmented = curve_header + struct.pack(">HH2f", 3, 0, 0, 1) + identity + sampled + identity
    logarithmic = curve_header + struct.pack(">HH", 1, 0) + formula(1, 1, .8, 1, 1, 0)
    exponential = curve_header + struct.pack(">HH", 1, 0) + formula(2, 1, 2, .8, 0, -1)
    curves = (segmented, logarithmic, exponential)
    positions = [(36 + sum(map(len, curves[:i])), len(curve)) for i, curve in enumerate(curves)]
    cvst = b"cvst" + bytes(4) + struct.pack(">HH", 3, 3)
    cvst += b"".join(struct.pack(">II", *pair) for pair in positions) + b"".join(curves)
    mpe_curves = b"mpet" + bytes(4) + struct.pack(">HHIIIII", 3, 3, 2, 32, len(cvst), 32 + len(cvst), len(stage))
    cases.append(("mpet-curves", build_profile({**tags, b"D2B1": mpe_curves + cvst + stage}), b""))
    compared = {}
    for variant, profile, extra in cases:
        # For an unknown element, compare the ICC.1 fallback against LittleCMS
        # using the same matrix/TRCs without the unknown stage.
        reference_profile = build_profile(tags) if variant == "mpet-fallback" else profile
        source_profile = ImageCms.ImageCmsProfile(BytesIO(reference_profile))
        ref = ImageCms.profileToProfile(image, source_profile, srgb, renderingIntent=1, outputMode="RGBA")
        compared[variant] = ref.tobytes()
        metadata = extra or chunk(b"iCCP", b"Test RGB\0\0" + zlib.compress(profile))
        layer = png(len(values), 1, 8, lambda x, y: values[x], metadata)
        source = OUT / f"{variant}.ora"
        output = OUT / f"{variant}-edited.ora"
        output.unlink(missing_ok=True)
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("mimetype", "image/openraster")
            archive.writestr("stack.xml", f'<image version="0.0.6" w="{len(values)+1}" h="1"><stack><layer name="Profiled" src="data/input.png"/></stack></image>')
            archive.writestr("data/input.png", layer)
            pixels = list(ref.getdata()) + [(0, 0, 0, 0)]
            preview = png(len(pixels), 1, 8, lambda x, y: pixels[x])
            archive.writestr("mergedimage.png", preview)
            archive.writestr("Thumbnails/thumbnail.png", preview)
        edit = OUT / "icc-edit.json"
        edit.write_text('[{"path":[0],"x":1}]', encoding="utf-8")
        subprocess.run(["node", str(cli), "edit", str(source), str(output), str(edit)], check=True)
        with zipfile.ZipFile(output) as archive:
            stack = ET.fromstring(archive.read("stack.xml"))
            assert archive.read(stack.find("./stack/layer").get("src")) == layer
            rendered = decode_rgba(archive.read("mergedimage.png"))
            assert rendered[:3] == (len(values) + 1, 1, 8)
            assert rendered[3][0] == (0, 0, 0, 0)
            for actual, reference in zip(rendered[3][1:], ref.getdata()):
                assert max(abs(a - b) for a, b in zip(actual, reference)) <= 1, (variant, actual, reference)
                assert actual[3] == reference[3]
    assert compared["mpet-xyz"] == compared["mpet-clut"]
    assert compared["mpet-xyz"] != compared["mpet-other-intent"]
    assert compared["mpet-fallback"] == compared["mpet-other-intent"]
    print("PASS: ICC matrix, LUT and floating-point transforms match LittleCMS and retain original PNG bytes")
    print("PASS: P3 cICP and cHRM conversions match LittleCMS")
    check_float_icc_rgba16(cli, matrix_profile)


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
    check_icc_profiles(cli)
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
