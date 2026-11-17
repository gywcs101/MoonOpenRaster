# Fixture provenance

`krita-5.3.4.ora` and `krita-5.3.4.png` were exported using official Krita 5.3.4 for Windows from the generated Light study sample in this project. The artwork is original to MoonOpenRaster and is distributed under the project MIT license.

The ORA was independently rewritten by Krita, including cropped layer resources and adjusted layer offsets. The PNG is Krita's independent composite. The project CLI renders this ORA with exact byte equality to the PNG on the tested sample.

See scripts/check_krita.py for a live edit/export/reopen workflow. Krita itself is downloaded separately from https://download.kde.org/stable/krita/5.3.4/ and is not distributed with this repository.

The `capitole-krita.png` reference is Krita 5.3.4's independent rendering of the web-sized source-layer artwork in `web/assets/capitole.ora`. `artwork-validation.json` records the pinned source, original layer names, translations, converted extents and measured pixel error. These artwork files retain David Revoy's source terms; see `LICENSES/capitole-artwork-NOTICE.txt`. Regenerate from the original zip with `scripts/prepare_artwork.py` and verify with `scripts/check_artwork.py`.

The additional `samples/*-krita.png` files are independent Krita renderings of the normalized originals, not screenshots of the workbench. Their provenance and pixel measurements are in `sample-validation.json`; see LICENSES/sample-artworks-NOTICE.txt.
