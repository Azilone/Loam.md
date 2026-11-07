#!/usr/bin/env python3
"""Traces the heavy extended "Loam" wordmark from a reference PNG (black on white) into brand/wordmark/heavy-path.txt
(one SVG path, baseline at y=0, cap height 706 like the Gerstner outlines) and wordmark-heavy-*.svg.
    .venv/bin/python brand/scripts/trace.py reference.png"""
import sys, os
import numpy as np
from PIL import Image
import potrace

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
img = Image.open(sys.argv[1]).convert("L")
a = np.array(img) < 128
ys, xs = np.where(a)
x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
a = a[max(0, y0 - 8):y1 + 8, max(0, x0 - 8):x1 + 8]
ox, oy = x0 - max(0, x0 - 8), y0 - max(0, y0 - 8)
plist = potrace.Bitmap(~a).trace(turdsize=20, alphamax=1.0, opticurve=True, opttolerance=0.4)
s = 706.0 / (y1 - y0)
def P(p): return f"{(p.x - ox) * s:.1f} {(p.y - oy) * s - 706:.1f}"
d = ""
for curve in plist:
    d += f"M{P(curve.start_point)}"
    for seg in curve.segments:
        d += (f"L{P(seg.c)}L{P(seg.end_point)}" if seg.is_corner else f"C{P(seg.c1)} {P(seg.c2)} {P(seg.end_point)}")
    d += "Z"
w = (x1 - x0) * s
open(os.path.join(ROOT, "wordmark", "heavy-path.txt"), "w").write(f"{w:.1f}\n{d}\n")
for name, col in [("black", "#0E0E10"), ("blue", "#1F5CFF"), ("white", "#FFFFFF")]:
    open(os.path.join(ROOT, "wordmark", f"wordmark-heavy-{name}.svg"), "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-20 -{706+20} {w+40:.0f} {706+40}" width="{(w+40)/4:.0f}"><path d="{d}" fill="{col}" fill-rule="evenodd"/></svg>\n')
print("traced", len(plist), "curves, width", round(w), "for cap 706")
