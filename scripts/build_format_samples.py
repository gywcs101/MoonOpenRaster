"""Generate original image-format practice artwork and starter documents."""
from io import BytesIO
import math
from pathlib import Path
import subprocess
import zipfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "web/assets/import-samples"
W, H = 480, 288


def label(draw, position, text, size, color):
    draw.text(position, text, font=ImageFont.load_default(size=size), fill=color)


def board(title, number, dark, accent, caption):
    image = Image.new("RGBA", (W, H), dark)
    draw = ImageDraw.Draw(image)
    draw.rectangle((16, 16, 464, 272), outline=accent)
    draw.line((29, 46, 451, 46), fill=accent)
    label(draw, (29, 24), title, 15, accent)
    label(draw, (397, 24), number, 13, accent)
    label(draw, (29, 240), caption, 16, accent)
    return image


def seed(name, base, layer_name, overlay, x, y):
    def png(image):
        stream = BytesIO()
        image.save(stream, "PNG")
        return stream.getvalue()

    preview = base.copy()
    preview.alpha_composite(overlay, (x, y))
    with zipfile.ZipFile(OUT / (name + ".ora"), "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), "image/openraster")
        archive.writestr(zipfile.ZipInfo("stack.xml"), f'<image version="0.0.6" name="{name}" w="{W}" h="{H}"><stack><layer name="{layer_name}" x="{x}" y="{y}" src="data/panel.png"/><layer name="底板" src="data/base.png"/></stack></image>')
        archive.writestr(zipfile.ZipInfo("data/base.png"), png(base))
        archive.writestr(zipfile.ZipInfo("data/panel.png"), png(overlay))
        archive.writestr(zipfile.ZipInfo("mergedimage.png"), png(preview))
        archive.writestr(zipfile.ZipInfo("Thumbnails/thumbnail.png"), png(preview.resize((256, 153))))


def postcard():
    base = board("PACIFIC SIGNAL / FIELD POSTCARD", "N.017", "#172c38", "#a9d1c8", "WATERLINE STUDIES       37.8 N")
    size = (296, 171)
    seed("postcard", base, "照片窗口", Image.new("RGBA", size, "#355664"), 30, 58)
    photo = Image.new("RGB", size)
    def landscape(x, y):
        if y < 104:
            light = y / 110 * (1 - abs(x - 184) / 245)
            return tuple(int(v + light * gain) for v, gain in ((65, 143), (119, 94), (151, 46)))
        wave = int(10 * math.sin(y / 2.7 + math.sin(x / 17)))
        return (25 + wave, 80 + wave, 99 + wave)
    photo.putdata([landscape(x, y) for y in range(171) for x in range(296)])
    draw = ImageDraw.Draw(photo)
    draw.polygon([(0, 129), (36, 112), (69, 105), (119, 105), (141, 121), (109, 146), (0, 159)], fill="#233b48")
    draw.ellipse((176, 70, 198, 92), fill="#ffdb96")
    photo.save(OUT / "tide.jpg", quality=93, progressive=False)
    stamp = Image.new("RGBA", (95, 107))
    draw = ImageDraw.Draw(stamp)
    draw.rounded_rectangle((4, 4, 91, 102), radius=13, fill=(239, 190, 139, 215), outline="#ffe0b8", width=2)
    draw.ellipse((25, 34, 72, 81), outline="#573841", width=2)
    label(draw, (34, 47), "017", 17, "#573841")
    stamp.save(OUT / "stamp.webp", lossless=True)
    mark = Image.new("RGBA", (48, 36))
    ImageDraw.Draw(mark).line((3, 29, 21, 5, 29, 19, 43, 7), fill="#f8dcab", width=4, joint="curve")
    mark.save(OUT / "tide-mark.png")


def atlas():
    base = board("MERIDIAN / ELEVATION STUDY", "16 BIT", "#142a2c", "#91c6a7", "SURVEY GRID        SHEET 06")
    w, h = 351, 166
    seed("atlas", base, "高程窗口", Image.new("RGBA", (w, h), "#33494b"), 30, 58)
    def height(x, y):
        distance = math.hypot((x - 164) / 1.45, y - 80)
        return 10001 + int((1 - min(distance / 150, 1)) * 37001 + (math.cos(distance / 12) + 1) * 1910)
    raw = b"".join(height(x, y).to_bytes(2, "little") for y in range(h) for x in range(w))
    Image.frombytes("I;16", (w, h), raw).save(OUT / "elevation.tiff")
    key = Image.new("RGB", (62, 145), "#d5d8bc")
    draw = ImageDraw.Draw(key)
    label(draw, (8, 7), "KEY", 12, "#173230")
    for i, color in enumerate(("#efebcd", "#c5ceb0", "#90a891", "#58756a", "#283e3d")):
        draw.rectangle((9, 30 + 20 * i, 51, 44 + 20 * i), fill=color)
    key.save(OUT / "legend.bmp")
    # Use the same reference geometry in both the standalone SVG and saved ORA.
    contours = [
        '<ellipse cx="172" cy="81" rx="44" ry="20"/>',
        '<ellipse cx="172" cy="81" rx="83" ry="39"/>',
        '<ellipse cx="172" cy="81" rx="122" ry="59"/>',
        '<ellipse cx="172" cy="81" rx="156" ry="75"/>',
    ]
    (OUT / "contours.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="351" height="166" viewBox="0 0 351 166">'
        '<g fill="none" stroke="#d6f4c4" stroke-width="1.5" opacity=".86">'
        + "".join(contours) + '</g></svg>\n', encoding="utf-8"
    )



def signal():
    base = board("NIGHT SERVICE / DEPARTURES", "P-03", "#242044", "#dfb6ef", "PLATFORM 03        LOCAL SERVICE")
    draw = ImageDraw.Draw(base)
    for y in range(66, 220, 34):
        draw.rounded_rectangle((37, y, 440, y + 25), radius=5, fill="#342958")
        for x in range(113, 426, 42):
            draw.rectangle((x, y + 9, x + 22, y + 11), fill="#604c7d")
    seed("signal", base, "灯牌", Image.new("RGBA", (65, 27), "#4d3b77"), 44, 100)
    frames = []
    for color in ("#f1b770", "#91e2bc", "#bb8cf1"):
        item = Image.new("RGB", (65, 27), "#31234b")
        draw = ImageDraw.Draw(item)
        draw.rounded_rectangle((4, 4, 60, 22), radius=8, fill=color)
        label(draw, (12, 5), "LOCAL", 13, "#31234b")
        frames.append(item)
    frames[0].save(OUT / "departures.gif", save_all=True, append_images=frames[1:], duration=180, loop=0)
    icon = Image.new("RGBA", (64, 64))
    draw = ImageDraw.Draw(icon)
    draw.ellipse((6, 6, 57, 57), fill="#a6e7c4", outline="#e0ffd8", width=3)
    draw.polygon([(20, 32), (33, 19), (45, 32), (33, 45)], fill="#352752")
    icon.save(OUT / "station.ico", sizes=[(16, 16), (32, 32), (64, 64)])


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    postcard()
    atlas()
    signal()
    subprocess.run(["node", "scripts/build_format_catalog.mjs"], cwd=ROOT, check=True)
