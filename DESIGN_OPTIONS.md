# Selected workbench design

The user selected the professional studio design. Alternative styles and the style selector were removed.

The selected interface follows the locally installed ui-design Product UI guidance: a dominant work surface, a quiet left layer rail and a fixed-width right inspector. Inter Variable is used for controls, with Instrument Serif for the product wordmark and a serif Chinese fallback for the selected-layer title. The separate M emblem is removed. Fonts are bundled for offline use. Layer selection, thumbnail, dimensions and visibility share one consistent row.

The default artwork is David Revoy’s Capitole du libre illustration, converted from its original layered KRA source with Krita. The gallery contains four authentic source-layer works and separate guided practice variants. No fabricated title/shape layers are overlaid on a flat poster. Source terms and conversion details are in LICENSES and fixtures. X/Y and dragging move the complete selected raster layer. Group offsets are disabled according to OpenRaster semantics.

Launch with `python scripts/serve_web.py`. The launcher compiles the core, anchors the web directory to this repository and disables browser caching. CSS, entry script and compiled core URLs also carry a revision identifier so earlier cached resources do not mix with this layout.
