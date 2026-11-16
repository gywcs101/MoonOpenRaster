# Validation status

This records completed checks and outstanding acceptance work separately.

## Verified locally

- MoonBit 0.10.20 with moon 0.1.20261104.
- Static checking across native, JavaScript, wasm and wasm-gc.
- JavaScript unit tests cover owned image buffers, basic analytical pixel operations, transparent inputs for all 20 operations, isolated group opacity, negative offsets, persistent nested edits, ORA round trips and multi-color PNG reimport.
- Independent Python ZIP/XML input with Deflate-compressed PNG entries is read by the JavaScript CLI. Rendered pixels are compared exactly with Pillow alpha composition.
- ORA output is independently inspected with Python zipfile and ElementTree. Tests check the first uncompressed mimetype entry, extension metadata, extra resources, merged preview and thumbnail.
- The browser workspace was opened and its sample, layer selection, Chinese renaming and visibility controls were exercised.

## Acceptance work still pending

- Full analytical vectors for every blend mode, reference validation of nonseparable modes and pass-through group opacity.
- Native executable tests. Local Visual Studio component paths exist, but a usable MSVC compiler and Windows SDK environment has not yet been established.
- Krita-generated fixtures and bidirectional Krita editing/visual comparison. Pillow comparison does not establish Krita interoperability.
- Readable inspection and unchanged preservation of unsupported vector layers, unknown XML elements, ICC profiles and 16-bit input.
- Fully documented aggregate decode, canvas and nested-buffer memory limits.
- Full layer insertion/deletion/reordering and group expand/collapse controls in the web UI.
- Packaged-consumer execution and complete redistributed dependency license audit.
- Green GitHub CI. The first observed run failed during job setup before running project commands.

No Mooncakes version has been published. No contest application has been submitted.
