"""Reproducible worker-protocol benchmark; writes test ORAs, not release packages."""
from pathlib import Path
import io
import json
import subprocess
import sys
import zipfile
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
work = ROOT / "_build/performance"
work.mkdir(parents=True, exist_ok=True)
cases = []
for width, layers, depth in [(1000, 8, 2), (2048, 4, 2), (512, 4, 24)]:
    image = Image.new("RGBA", (width, width))
    image.putdata([((x // 8) % 256, (y // 8) % 256, 128, 128) for y in range(width) for x in range(width)])
    source = io.BytesIO(); image.save(source, "PNG")
    merged = Image.new("RGBA", image.size)
    for _ in range(layers): merged = Image.alpha_composite(merged, image)
    preview = io.BytesIO(); merged.save(preview, "PNG")
    filename = work / f"{width}-{layers}.ora"
    xml = f'<image w="{width}" h="{width}"><stack>' + ''.join(f'<stack name="group{i}" isolation="isolate">' for i in range(depth))
    xml += ''.join(f'<layer name="layer{i}" src="data/layer{i}.png"/>' for i in range(layers))
    xml += '</stack>' * (depth + 1) + '</image>'
    with zipfile.ZipFile(filename, "w") as archive:
        archive.writestr("mimetype", "image/openraster")
        archive.writestr("stack.xml", xml)
        for index in range(layers): archive.writestr(f"data/layer{index}.png", source.getvalue())
        archive.writestr("mergedimage.png", preview.getvalue())
    cases.append({"name": f"{width}px-{layers}layers-{depth}groups", "file": str(filename), "layers": layers})
(work / "cases.json").write_text(json.dumps(cases), encoding="utf-8")
subprocess.run(["node", "--expose-gc", "scripts/benchmark_editor.mjs", str(work / "cases.json"), str(work / ((sys.argv[1] if len(sys.argv) > 1 else "current") + ".json"))], cwd=ROOT, check=True)
