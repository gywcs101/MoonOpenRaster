# Fixture provenance

`krita-5.3.4.ora` and `krita-5.3.4.png` were exported using official Krita 5.3.4 for Windows from the generated Light study sample in this project. The artwork is original to MoonOpenRaster and is distributed under the project MIT license.

The ORA was independently rewritten by Krita, including cropped layer resources and adjusted layer offsets. The PNG is Krita's independent composite. The project CLI renders this ORA with exact byte equality to the PNG on the tested sample.

See scripts/check_krita.py for a live edit/export/reopen workflow. Krita itself is downloaded separately from https://download.kde.org/stable/krita/5.3.4/ and is not distributed with this repository.
