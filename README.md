# MoonOpenRaster

MoonBit library for OpenRaster layered documents, with a command-line interface and a local browser workspace.

Core read/edit/render/write paths have independent Krita and Pillow validation. See [VALIDATION.md](VALIDATION.md) for exact compatibility, resource limits and platform evidence.

## Quick start

Use MoonBit 0.10.20 or newer, Node.js and Python 3.

```sh
moon update
moon check --target all --deny-warn
moon test --target js --deny-warn
python scripts/serve_web.py
```

For a self-contained distribution with compiled MoonBit code and license notices, run `python scripts/package_web.py` and use `_build/publish/MoonOpenRaster-web.zip`.

The launcher builds the JavaScript core and serves from the correct web directory with browser caching disabled. Stop older servers before starting it.

Open http://127.0.0.1:8765 in a browser. The workbench loads a real source-layer illustration by David Revoy (7 original painting layers, translated names, resized to 1000 × 1000). Drag layers with live previews, undo/redo, zoom/pan, import/replace PNG layers, manage groups, extract layer PNGs and save PNG or ORA. See the [中文使用说明](docs/WORKBENCH.zh-CN.md). Processing happens locally. The browser import limit is 32 MiB.

## Library

```moonbit
let image = @ora.Image::new(1, 1, [255, 0, 0, 255])
let layer = @ora.Node::Layer(@ora.Properties::new("Red"), image)
let document = @ora.Document::new(1, 1, [layer])
let archive = document.write()
let reopened = @ora.read(archive)
let png = reopened.render().encode_png()
```

Import `gywcs101/MoonOpenRaster` with alias `ora` in your package configuration. Public interfaces are in `pkg.generated.mbti`.

## Command line

```sh
moon run cmd/main --target js -- inspect drawing.ora
moon run cmd/main --target js -- render drawing.ora composite.png
moon run cmd/main --target js -- edit drawing.ora changed.ora edits.json
```

Outputs must not already exist. The edit file is an array of full property replacements. Paths use zero-based indices from the top of the layer stack. Group children append another index.

```json
[{"path":[0,0],"name":"Moved layer","x":20,"y":10,"visible":true,"opacity":0.5,"composite_op":"svg:src-over"}]
```

## Independent validation

Install Pillow in your test environment, then run the generated independent fixture and pixel comparison.

```sh
python scripts/check_interop.py
python scripts/build_web.py
node scripts/check_bridge.mjs
node scripts/check_editor.mjs
python scripts/check_artwork.py
python scripts/check_krita.py
python scripts/check_package.py
```

## Format support

The current renderer accepts 8-bit raster PNG layers, clipped canvas placement, nested groups and the 20 baseline SVG composite operators. It implements isolated and pass-through group paths, and Krita’s `alpha-preserve="true"` blending extension. Unknown operations are rejected when rendering. The editing reader rejects unsupported PNG bit depths and unknown layer elements. Structural inspection and the browser can show their original preview and export the original archive unchanged. Extension attributes and additional archive resources are preserved for supported documents.

The core format work follows the [OpenRaster baseline specification](https://www.openraster.org/baseline/baseline.html). ZIP, XML and PNG processing reuse MoonBit ecosystem components. See [THIRD_PARTY.md](THIRD_PARTY.md).

MIT License. Copyright 2026 gywcs101.

Krita 5.3.4 differs from the standard `svg:plus` alpha rule in the tested sample. Additive-layer visual equality across these implementations is not guaranteed; numerical evidence is recorded in VALIDATION.md.
