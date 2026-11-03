# Loam brand kit

Wordmark: Gerstner Programm (outlined; the font files are licensed and not in this repository, put them in `fonts/` to rebuild the sheet). Mono labels: FT System Mono. Blue `#1F5CFF`, paper `#F5F4EF`, ink `#0E0E10`.

- `glyph/` the mark alone (blue, black, white).
- `wordmark/` "Loam" in Gerstner Programm medium and regular (black, blue, white), a heavy extended one (black, blue, white), and a medium extended one (black).
- `logo/` glyph + wordmark in six treatments (clean, dither, grain, print, line, ink), each in regular, `-extended` and `-heavy`. Dither also has `-landing` and `-landing-inline`, regular and `-extended`.
- `icon/` macOS app icons (clean, glass, light, dark, textured, outline, monochrome, leaf), and the real ones for Icon Composer: `Loam-green.icon` (the app icon, a copy of `App/Resources/Loam.icon`) and `Loam.icon` (blue, the Dither theme), their layers rendered by `icon/render-icon-layers.swift` (`swift icon/render-icon-layers.swift <Assets> [blue]`).
- `brand-sheet.html` / `.png` everything on one page.

Rebuild, from `brand/`: `.venv/bin/python scripts/build.py && python3 scripts/sheet.py`. The `.venv` is not in the repository: create it with `python3 -m venv .venv && .venv/bin/pip install fonttools brotli`. PNGs: `scripts/render.swift`.
