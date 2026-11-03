#!/usr/bin/env python3
"""Builds the Loam brand kit: glyph, wordmark (Gerstner Programm, outlined), logo and app-icon variations as SVG.

    python3 -m venv .venv && .venv/bin/pip install fonttools brotli && .venv/bin/python brand/scripts/build.py
"""
import math, os, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLUE, DEEP, PAPER, INK, CREAM = "#1F5CFF", "#0B3DDB", "#F5F4EF", "#0E0E10", "#F7F6F1"

def write(path, s):
    os.makedirs(os.path.dirname(os.path.join(ROOT, path)), exist_ok=True)
    open(os.path.join(ROOT, path), "w").write(s)

# ---------------------------------------------------------------- glyph
# The mark, as drawn for the app icon (icon/render-icon-layers.swift): a pebble stem narrowing to its foot, a lens leaf,
# a leaf lying below. Cubic paths on the 1024 canvas, placed by the same transform as the icon.
GLYPH_1024 = [
    [(246, 340), (246, 284, 274, 254, 322, 254), (438, 252), (466, 252, 480, 272, 478, 300), (470, 520, 420, 720, 296, 744), (262, 750, 246, 738, 246, 708)],
    [(494, 572), (490, 456, 590, 366, 720, 362), (732, 362, 738, 372, 736, 386), (718, 486, 620, 566, 494, 572)],
    [(396, 744), (424, 676, 470, 626, 528, 624), (694, 622), (724, 622, 742, 640, 740, 666), (736, 716, 708, 744, 664, 744)],
]
place = lambda x, y: (((x - 493) * 1.06 + 506) / 1024, ((y - 498) * 1.06 + 506) / 1024)

def glyph_path(m):
    d = ""
    for piece in GLYPH_1024:
        d += "M" + m(*place(*piece[0])) + " "
        for seg in piece[1:]:
            if len(seg) == 2: d += "L" + m(*place(*seg)) + " "
            else: d += "C" + " ".join(m(*place(seg[i], seg[i + 1])) for i in (0, 2, 4)) + " "
        d += "Z"
    return d

_xs = [place(x, 0)[0] for piece in GLYPH_1024 for seg in piece for x in seg[0::2]]
_ys = [place(0, y)[1] for piece in GLYPH_1024 for seg in piece for y in seg[1::2]]
X0, X1, Y0, Y1 = min(_xs), max(_xs), min(_ys), max(_ys)

GW = 1000.0
S = GW / (X1 - X0)
GH = round((Y1 - Y0) * S)
glyph_local = glyph_path(lambda x, y: f"{(x - X0) * S:.1f} {(y - Y0) * S:.1f}")

# ---------------------------------------------------------------- wordmark: Gerstner Programm outlines
def word_path(weight, text="Loam", track=-12):
    f = TTFont(os.path.join(ROOT, "fonts", f"gerstner-programm-{weight}.woff2"))
    gs, cm, hmtx = f.getGlyphSet(), f.getBestCmap(), f["hmtx"]
    x, d = 0, ""
    for ch in text:
        name = cm[ord(ch)]
        pen = SVGPathPen(gs)
        gs[name].draw(TransformPen(pen, (1, 0, 0, -1, x, 0)))   # flip: font y goes up
        d += pen.getCommands()
        x += hmtx[name][0] + track
    return d, x - track
CAP = 706
word_medium, word_w = word_path("medium")
word_regular, _ = word_path("regular")
heavy_w, heavy_d = open(os.path.join(ROOT, "wordmark", "heavy-path.txt")).read().split("\n")[:2]   # traced by trace.py
heavy_w = float(heavy_w)

# ---------------------------------------------------------------- effects
def bayer(n):
    if n == 1: return [[0]]
    p = bayer(n // 2); k = len(p)
    return [[4 * p[y % k][x % k] + [[0, 2], [3, 1]][y // k][x // k] for x in range(n)] for y in range(n)]
B8 = bayer(8)

def dither_cells(x0, y0, w, h, cell, field, tail=0.0):
    """Squares of an 8x8 ordered dither over a box; field(u,v) in 0..1 is the density. Returns (on, edge) path data."""
    on, edge = [], []
    for cy in range(int(h / cell) + 1):
        for cx in range(int(w / cell) + 1):
            f, t = field(cx * cell / w, cy * cell / h), (B8[cy % 8][cx % 8] + .5) / 64
            sq = f"M{x0 + cx*cell:.1f} {y0 + cy*cell:.1f}h{cell}v{cell}h-{cell}z"
            if f > t: on.append(sq)
            elif f > t - tail: edge.append(sq)
    return "".join(on), "".join(edge)

GRAIN = lambda id, freq=.9, lo=.40, hi=.47, rough=0: f'''<filter id="{id}" x="-4%" y="-4%" width="108%" height="108%" color-interpolation-filters="sRGB">
<feTurbulence type="fractalNoise" baseFrequency="{freq}" numOctaves="2" seed="7" result="n"/>
<feColorMatrix in="n" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 {1/(hi-lo):.1f} 0 0 0 {-lo/(hi-lo):.2f}" result="holes"/>
{f'<feTurbulence type="fractalNoise" baseFrequency=".02" numOctaves="2" seed="2" result="w"/><feDisplacementMap in="SourceGraphic" in2="w" scale="{rough}" result="sg"/>' if rough else '<feOffset in="SourceGraphic" result="sg"/>'}
<feComposite in="sg" in2="holes" operator="in"/></filter>'''

# ---------------------------------------------------------------- lockups
def lockup(variant, weight="medium", extended=False, blue=BLUE, light="#A9C4FF", dark="#0A2FB0", cells=46, inline=False, dens=1.1, face="gerstner"):
    wp = word_medium if weight == "medium" else word_regular
    heavy = face == "heavy"
    if heavy: wp = heavy_d
    Hg = CAP * 1.38
    sg = Hg / GH
    gx, gy = 0, -CAP / 2 - Hg / 2   # the baseline is y=0 and the caps rise to -CAP
    gap = Hg * 0.30
    sx = 1.34 if extended else 1.0
    tx = GW * sg + gap
    ww = (heavy_w if heavy else word_w) * sx
    pad = Hg * 0.12
    W, H = tx + ww + 2 * pad, Hg + 2 * pad
    vb = f"{-pad:.0f} {gy - pad:.0f} {W:.0f} {H:.0f}"
    emb = 28 if extended else 0   # extended wordmark is also emboldened, like the heavy wordmark in the references
    glyph = f'<path transform="translate({gx} {gy}) scale({sg:.4f})" d="{glyph_local}"/>'
    word = f'<path transform="translate({tx:.1f} 0) scale({sx} 1)" d="{wp}"' + (f' stroke-width="{emb}" stroke-linejoin="round"' if emb else '') + (' fill-rule="evenodd" clip-rule="evenodd"' if heavy else '') + '/>'
    shapes = glyph + word
    defs, body = "", ""
    if variant == "clean":
        body = f'<g fill="{BLUE}">{glyph}</g><g fill="{INK}" stroke="{INK}">{word}</g>'
    elif variant == "dither":
        bx0, by0, bw, bh = -pad, gy - pad, W, H
        on, edge = dither_cells(bx0, by0, bw, bh, Hg / cells, lambda u, v: max(0, min(1, dens - 1.25 * math.hypot(u * 1.2 - .05, v - .9) + .05 * math.sin(40 * u))), .05)
        defs = f'<clipPath id="c">{shapes}</clipPath>'
        body = (f'<g clip-path="url(#c)"><rect x="{bx0}" y="{by0}" width="{bw}" height="{bh}" fill="{blue}"/>'
                f'<path d="{edge}" fill="{dark}" opacity=".5"/><path d="{on}" fill="{light}" opacity=".85"/></g>')
    elif variant == "grain":
        defs = GRAIN("g", .85, .40, .47, 5)
        body = f'<g filter="url(#g)" fill="{INK}" stroke="{INK}">{shapes}</g>'
    elif variant == "print":
        defs = GRAIN("g", .8, .37, .46, 7)
        body = (f'<g fill="#5B8CFF" stroke="#5B8CFF" opacity=".85" transform="translate(9 7)" filter="url(#g)">{shapes}</g>'
                f'<g fill="{BLUE}" stroke="{BLUE}" filter="url(#g)" opacity=".95">{shapes}</g>')
    elif variant == "line":
        defs = f'<pattern id="h" width="14" height="14" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="14" stroke="{BLUE}" stroke-width="3.2"/></pattern>'
        body = f'<g fill="url(#h)" stroke="{BLUE}" stroke-width="5" stroke-linejoin="round">{shapes}</g>'
    elif variant == "ink":
        defs = GRAIN("g", .7, .36, .44, 9)
        body = f'<g filter="url(#g)" fill="#141414" stroke="#141414" stroke-width="2">{shapes}</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" {"" if inline else f' width="{W/4:.0f}" height="{H/4:.0f}"'}><defs>{defs}</defs>{body}</svg>\n'

VARIANTS = ["clean", "dither", "grain", "print", "line", "ink"]
for v in VARIANTS:
    write(f"logo/lockup-{v}.svg", lockup(v))
    write(f"logo/lockup-{v}-extended.svg", lockup(v, extended=True))
    write(f"logo/lockup-{v}-heavy.svg", lockup(v, face="heavy"))

# the dither lockup in the landing page's own colours (--primary, --dither-ice), coarser cells for a 30 px nav logo
SAGE = dict(blue="#5E7B58", light="#C4D1C0", dark="#3E5A3A", cells=40, dens=1.1)   # the landing page's brand green
write("logo/lockup-dither-extended-landing.svg", lockup("dither", extended=True, **SAGE))
write("logo/lockup-dither-extended-landing-inline.svg", lockup("dither", extended=True, inline=True, **SAGE).replace('id="c"', 'id="loam-dither"').replace('url(#c)', 'url(#loam-dither)'))
write("logo/lockup-dither-landing.svg", lockup("dither", blue="#155EEF", light="#DDEBFF", dark="#0B3AA8", cells=22, dens=.72))
write("logo/lockup-dither-landing-inline.svg", lockup("dither", blue="#155EEF", light="#DDEBFF", dark="#0B3AA8", cells=22, dens=.72, inline=True).replace('id="c"', 'id="loam-dither"').replace('url(#c)', 'url(#loam-dither)'))

# stand-alone glyph and wordmark in three colours
for name, col in [("blue", BLUE), ("black", INK), ("white", "#FFFFFF")]:
    write(f"glyph/glyph-{name}.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {GW:.0f} {GH:.0f}" width="256"><path d="{glyph_local}" fill="{col}"/></svg>\n')
    for w, p in [("medium", word_medium), ("regular", word_regular)]:
        write(f"wordmark/wordmark-{w}-{name}.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-20 -{CAP+20} {word_w+40:.0f} {CAP+40}" width="{(word_w+40)/4:.0f}"><path d="{p}" fill="{col}"/></svg>\n')
write("wordmark/wordmark-extended-black.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-40 -{CAP+40} {word_w*1.34+80:.0f} {CAP+80}" width="{(word_w*1.34+80)/4:.0f}"><path transform="scale(1.34 1)" d="{word_medium}" fill="{INK}" stroke="{INK}" stroke-width="28" stroke-linejoin="round"/></svg>\n')

# ---------------------------------------------------------------- app icons (1024 canvas, 824 tile)
T, M = 824, 100
R = T * 0.2237
full = lambda x, y: f"{M + T * x:.1f} {M + T * y:.1f}"
G_ICON = glyph_path(full)
TILE = f'<rect x="{M}" y="{M}" width="{T}" height="{T}" rx="{R:.0f}"'
SHADOW = lambda op=.35: f'<filter id="s" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#04165C" flood-opacity="{op}"/></filter><clipPath id="c">{TILE}/></clipPath>'
def grad(id, a, b, c=None): return f'<linearGradient id="{id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{a}"/>' + (f'<stop offset=".5" stop-color="{c}"/>' if c else '') + f'<stop offset="1" stop-color="{b}"/></linearGradient>'
def icon_svg(defs, body): return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><defs>{defs}</defs>{body}</svg>\n'
def tile_dither(light, dark, lo_op, hi_op, cell=8, dens=1.0):
    on, edge = dither_cells(M, M, T, T, cell, lambda u, v: max(0, min(1, dens * (1.05 - 1.35 * math.hypot(u - .05, v - 1.0) / 1.15) + .07 * math.sin(6 * u + 4 * v))), .05)
    return f'<path d="{edge}" fill="{dark}" opacity="{lo_op}"/><path d="{on}" fill="{light}" opacity="{hi_op}"/>'
NOISE = lambda id, freq, op, color="0 0 0": f'<filter id="{id}" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="{freq}" numOctaves="2" seed="4"/><feColorMatrix type="matrix" values="0 0 0 0 {color.split()[0]} 0 0 0 0 {color.split()[1]} 0 0 0 0 {color.split()[2]} 0 0 0 {op*4} {-op*1.6:.2f}"/></filter>'

icons = {}
icons["clean"] = icon_svg(grad("b", "#2B6BFF", "#0B3DDB") + SHADOW(),
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><path d="{G_ICON}" fill="{CREAM}"/>')
icons["light"] = icon_svg(grad("b", "#FFFFFF", "#ECEAE3") + SHADOW(.22) + NOISE("n", .9, .10),
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><g clip-path="url(#c)">{tile_dither("#9DB8F5", "#6C8CE0", .12, .35, dens=.8)}<rect x="{M}" y="{M}" width="{T}" height="{T}" filter="url(#n)"/></g>'
    f'<path d="{G_ICON}" fill="{BLUE}"/>')
icons["dark"] = icon_svg(grad("b", "#26262B", "#0A0A0C") + SHADOW(.5) + NOISE("n", .85, .22, "1 1 1"),
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><g clip-path="url(#c)">{tile_dither("#FFFFFF", "#000000", .35, .10, dens=.7)}<rect x="{M}" y="{M}" width="{T}" height="{T}" filter="url(#n)"/></g>'
    f'<path d="{G_ICON}" fill="{CREAM}"/>')
icons["textured"] = icon_svg(grad("b", "#2F6BFF", "#0A27B4", "#1448EE") + SHADOW() + NOISE("n", .9, .16, "1 1 1"),
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><g clip-path="url(#c)">{tile_dither("#9DBCFF", "#051A8A", .45, .40)}<rect x="{M}" y="{M}" width="{T}" height="{T}" filter="url(#n)"/></g>'
    f'<path d="{G_ICON}" fill="{CREAM}"/>')
icons["outline"] = icon_svg(grad("b", "#FFFFFF", "#F1EFE8") + SHADOW(.18) + f'<pattern id="h" width="12" height="12" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="12" stroke="{BLUE}" stroke-width="3"/></pattern>',
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g>{TILE} fill="none" stroke="{BLUE}" stroke-width="8"/>'
    f'<path d="{G_ICON}" fill="url(#h)" stroke="{BLUE}" stroke-width="7" stroke-linejoin="round"/>')
icons["monochrome"] = icon_svg(grad("b", "#E4E3DE", "#C9C8C2") + SHADOW(.25) + NOISE("n", .8, .30),
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><g clip-path="url(#c)">{tile_dither("#FFFFFF", "#7A7974", .55, .20, dens=.9)}<rect x="{M}" y="{M}" width="{T}" height="{T}" filter="url(#n)"/></g>'
    f'<path d="{G_ICON}" fill="#171717"/>')
# leaf: the logo's leaf drawn as large vein-line art behind the glyph
leaves = ""
for i, (cx, cy, rot, sc) in enumerate([(.1, .95, -35, 2.4), (.95, .1, 150, 2.0), (.55, 1.05, -70, 1.6)]):
    leaves += f'<g transform="translate({M + T*cx:.0f} {M + T*cy:.0f}) rotate({rot}) scale({sc})" fill="none" stroke="#9DBCFF" stroke-width="2" opacity=".42"><path d="M0 0C0 -120 90 -210 250 -215C250 -80 160 0 0 0Z"/><path d="M0 0L250 -215"/>' + "".join(f'<path d="M{40*k} {-34*k}L{40*k+60} {-34*k+10}M{40*k} {-34*k}L{40*k+10} {-34*k+60}"/>' for k in range(1, 6)) + '</g>'
icons["leaf"] = icon_svg(grad("b", "#2F6BFF", "#0A27B4", "#1448EE") + SHADOW() + NOISE("n", .9, .12, "1 1 1"),
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><g clip-path="url(#c)">{leaves}{tile_dither("#9DBCFF", "#051A8A", .30, .28, dens=.6)}<rect x="{M}" y="{M}" width="{T}" height="{T}" filter="url(#n)"/></g>'
    f'<path d="{G_ICON}" fill="{CREAM}"/>')
# glass: frosted pane over the dithered tile (SVG imitation of the Liquid Glass render; the real one is Loam.icon)
icons["glass"] = icon_svg(grad("b", "#2F6BFF", "#0A27B4", "#1448EE") + SHADOW() + NOISE("n", .9, .12, "1 1 1") + f'''
<clipPath id="g"><path d="{G_ICON}"/></clipPath>
<linearGradient id="rim" x1="0" y1="0" x2=".35" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".95"/><stop offset=".45" stop-color="#fff" stop-opacity=".12"/><stop offset="1" stop-color="#bcd2ff" stop-opacity=".7"/></linearGradient>
<linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset=".55" stop-color="#eef3ff" stop-opacity=".55"/><stop offset="1" stop-color="#d6e4ff" stop-opacity=".62"/></linearGradient>
<linearGradient id="tr" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".8"/><stop offset=".3" stop-color="#fff" stop-opacity="0"/></linearGradient>
<filter id="frost" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="7"/></filter>
<filter id="gd" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#021250" flood-opacity=".45"/></filter>''',
    f'<g filter="url(#s)">{TILE} fill="url(#b)"/></g><g id="bg" clip-path="url(#c)">{tile_dither("#9DBCFF", "#051A8A", .45, .40)}<rect x="{M}" y="{M}" width="{T}" height="{T}" filter="url(#n)"/></g>'
    f'{TILE} fill="none" stroke="url(#tr)" stroke-width="5"/><path d="{G_ICON}" fill="#0a2fb0" filter="url(#gd)"/>'
    f'<g clip-path="url(#g)" filter="url(#frost)">{tile_dither("#9DBCFF", "#051A8A", .45, .40)}</g>'
    f'<path d="{G_ICON}" fill="url(#body)"/><path d="{G_ICON}" fill="none" stroke="url(#rim)" stroke-width="6" stroke-linejoin="round"/>')
for k, v in icons.items(): write(f"icon/icon-{k}.svg", v)
print("ok", len(icons), "icons,", len(VARIANTS) * 2, "lockups")
