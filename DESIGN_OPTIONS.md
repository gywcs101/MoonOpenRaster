# Selected workbench design

The user selected the professional studio design. Alternative styles and the style selector were removed.

The selected interface follows the locally installed ui-design Product UI guidance: a dominant work surface, a quiet left layer rail and a fixed-width right inspector. Inter Variable is used for controls, with Instrument Serif for the product wordmark and a serif Chinese fallback for the selected-layer title. The separate M emblem is removed. Fonts are bundled for offline use. Layer selection, thumbnail, dimensions and visibility share one consistent row.

The source NASA/JPL poster is one raster layer. Four independent PNG layers contain the added Chinese title, subtitle, rule and credit. X/Y and dragging move the complete selected layer. Group offsets are disabled according to OpenRaster semantics.

Launch with `python scripts/serve_web.py`. The launcher compiles the core, anchors the web directory to this repository and disables browser caching. CSS, entry script and compiled core URLs also carry a revision identifier so earlier cached resources do not mix with this layout.
