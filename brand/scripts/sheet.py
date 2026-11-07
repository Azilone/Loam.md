#!/usr/bin/env python3
"""Writes brand/brand-sheet.html: every variation on one page (fonts from brand/fonts)."""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lock = [("clean", "Classic and clear. Perfect for UI and small sizes."), ("dither", "Subtle dither, digital texture."), ("grain", "Organic grain, more analog."),
        ("print", "Rougher, more tactile, like paper."), ("line", "Light and technical, inspired by blueprints."), ("ink", "Bold and raw, with a hint of imperfection.")]
icons = [("clean", "Primary app icon."), ("glass", "Liquid Glass, over dither."), ("light", "Light mode or alternative."), ("dark", "Dark mode."),
         ("textured", "Adds character and depth."), ("outline", "Minimal and elegant."), ("monochrome", "For print or subtle use."), ("leaf", "Organic, inspired by the product.")]
cells = "".join(f'<div class="c"><img src="logo/lockup-{k}.svg"><img class="x" src="logo/lockup-{k}-extended.svg"><img class="x" src="logo/lockup-{k}-heavy.svg"><b>{k.upper()}</b><p>{d}</p></div>' for k, d in lock)
ic = "".join(f'<div class="i"><img src="icon/icon-{k}.svg"><b>{k.upper()}</b><p>{d}</p></div>' for k, d in icons)
html = f'''<!doctype html><meta charset="utf-8"><title>Loam brand</title><style>
@font-face{{font-family:G;src:url(fonts/gerstner-programm-regular.woff2);font-weight:400}}
@font-face{{font-family:G;src:url(fonts/gerstner-programm-medium.woff2);font-weight:500}}
@font-face{{font-family:M;src:url(fonts/ft-system-mono-regular.woff2)}}
*{{box-sizing:border-box;margin:0}}body{{background:#F5F4EF;color:#0E0E10;font:400 14px G,sans-serif;padding:40px}}
h2{{font:500 12px M;letter-spacing:.14em;text-transform:uppercase;margin:36px 0 4px}}.sub{{font:12px M;color:#777;margin-bottom:22px}}
.logos{{display:grid;grid-template-columns:repeat(3,1fr);gap:0;border-top:1px solid #e3e1da}}
.c{{padding:28px 24px;border-right:1px solid #e3e1da;border-bottom:1px solid #e3e1da}}.c img{{width:100%;display:block;margin-bottom:6px}}.c img.x{{opacity:1;margin-bottom:14px}}
b{{font:500 11px M;letter-spacing:.12em;display:block;margin-top:8px}}p{{font:12px M;color:#777;margin-top:4px;max-width:230px}}
.icons{{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}}.i img{{width:100%;margin-bottom:-20px}}.i{{padding:0 6px}}
.nav{{display:flex;align-items:center;gap:34px;background:#FBFAF6;border-radius:26px;padding:18px 30px;box-shadow:0 10px 30px #0001;margin:10px 0 40px}}
.nav img{{height:44px}}.nav a{{font:13px G;color:#222}}.nav a.on{{position:relative}}.nav a.on:after{{content:"";position:absolute;left:50%;bottom:-12px;width:4px;height:4px;border-radius:2px;background:#1F5CFF}}
.btn{{margin-left:auto;background:#1F5CFF;color:#fff;border-radius:20px;padding:10px 20px;font:13px G}}
.ctx{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}.ctx div{{border-radius:18px;height:260px;display:flex;align-items:center;justify-content:center}}
</style>
<h2>Logo typography variations</h2><div class="sub">Gerstner Programm, outlined. Each lockup in regular width, then extended, then the traced heavy wordmark.</div><div class="logos">{cells}</div>
<h2>App icon variations</h2><div class="sub">For macOS, different styles to match the brand tone.</div><div class="icons">{ic}</div>
<h2>Navigation bar (landing page)</h2><div class="sub">Minimal and clean. The active link uses a subtle blue accent.</div>
<div class="nav"><img src="logo/lockup-clean.svg"><a class="on">Features</a><a>AI &amp; Agents</a><a>Plugins</a><a>Local-First</a><a>GitHub</a><span class="btn">Download for macOS</span></div>
<h2>Logo in context</h2><div class="sub">Realistic usage in the app and on the website.</div>
<div class="ctx"><div style="background:linear-gradient(135deg,#8fb0d8,#1b3c6e)"><img src="icon/icon-glass.svg" width="200"></div><div style="background:#081a3a"><img src="logo/lockup-clean.svg" style="filter:brightness(0) invert(1);height:70px"></div></div>
'''
open(os.path.join(ROOT, "brand-sheet.html"), "w").write(html)
