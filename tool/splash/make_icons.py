# Builds the app icon: Lamar sitting in a paper grocery bag, peeking over the
# rim with his paws hooked on the edge, a baguette and a carrot poking out
# behind him. Drawn on a 40x40 pixel-art grid and scaled up by whole numbers so
# every art pixel stays crisp.
#
#   tool/splash/.venv/bin/python tool/splash/make_icons.py   (from repo root)
#   dart run flutter_launcher_icons
#
# Writes assets/icon/icon.png (full-bleed, iOS/web/legacy Android),
# assets/icon/icon_foreground.png (Android adaptive foreground), and
# build/icon_preview.png (circle / squircle / small-size check).
import os

import numpy as np
from PIL import Image, ImageDraw

N = 40  # art grid
T = None  # transparent

PINK_BG = (246, 213, 206)  # keep in sync with adaptive_icon_background in pubspec.yaml
BAG, BAG_RIM, BAG_SHADE, BAG_LINE = (200, 145, 90), (225, 178, 118), (176, 122, 72), (107, 68, 38)
BREAD, BREAD_CUT, BREAD_LINE = (228, 180, 108), (178, 118, 60), (120, 72, 30)
CARROT, CARROT_LINE = (240, 128, 44), (150, 62, 18)
LEAF, LEAF_LIGHT, LEAF_LINE = (88, 160, 62), (140, 198, 92), (34, 84, 34)

canvas = [[T] * N for _ in range(N)]


def put(x, y, c):
    if 0 <= x < N and 0 <= y < N:
        canvas[y][x] = c


def layer(paint, outline):
    """Paint a shape on its own layer, give it a 1-cell outline, then flatten
    it onto the canvas, so later layers overlap earlier ones cleanly."""
    lay = [[T] * N for _ in range(N)]

    def p(x, y, c):
        if 0 <= x < N and 0 <= y < N:
            lay[y][x] = c

    paint(p)
    filled = [[lay[y][x] is not None for x in range(N)] for y in range(N)]
    for y in range(N):
        for x in range(N):
            if filled[y][x]:
                continue
            if any(0 <= x + dx < N and 0 <= y + dy < N and filled[y + dy][x + dx]
                   for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                lay[y][x] = outline
    for y in range(N):
        for x in range(N):
            if lay[y][x] is not None:
                canvas[y][x] = lay[y][x]


def thick_line(p, x0, y0, x1, y1, r, color_at):
    steps = int(max(abs(x1 - x0), abs(y1 - y0)) * 4) + 1
    for i in range(steps + 1):
        t = i / steps
        cx, cy = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
        rr = r(t) if callable(r) else r
        for y in range(int(cy - rr) - 1, int(cy + rr) + 2):
            for x in range(int(cx - rr) - 1, int(cx + rr) + 2):
                if (x - cx) ** 2 + (y - cy) ** 2 <= rr * rr:
                    p(x, y, color_at(t, x, y))


# --- baguette, behind everything on the left, rising out of the bag
def baguette(p):
    def col(t, x, y):
        return BREAD_CUT if (x + y) % 5 == 0 and 0.15 < t < 0.95 else BREAD
    thick_line(p, 10, 25, 3.5, 4.5, 1.6, col)


# --- carrot on the right: tapering orange root, leafy top
def carrot(p):
    thick_line(p, 30, 25, 35.5, 9, lambda t: 1.8 - 1.1 * t, lambda t, x, y: CARROT)


def carrot_leaves(p):
    for (x0, y0, x1, y1) in ((35.5, 8.5, 32.5, 4), (35.5, 8.5, 36, 2.5), (35.5, 8.5, 38.5, 5)):
        thick_line(p, x0, y0, x1, y1, 0.55, lambda t, x, y: LEAF_LIGHT if t > 0.55 else LEAF)


layer(baguette, BREAD_LINE)
layer(carrot_leaves, LEAF_LINE)
layer(carrot, CARROT_LINE)

# --- Lamar's head: frame 0 of the dancing GIF, rows 0-14 (ears to just below
# the nose), placed so his chin disappears behind the bag rim.
gif = Image.open('assets/images/dancing_cat.gif')
gif.seek(0)
pal_img = np.array(gif.convert('P'))
rgb = np.array(gif.convert('RGB'))
transparent = gif.info.get('transparency')
ys, xs = np.where(pal_img != transparent)
top, left = ys.min(), xs.min()
HEAD_ROWS, HEAD_W = 16, 28
head_x, head_y = 6, 7
for r in range(HEAD_ROWS):
    for c in range(HEAD_W):
        if pal_img[top + r, left + c] != transparent:
            put(head_x + c, head_y + r, tuple(int(v) for v in rgb[top + r, left + c]))

# --- the bag, in front of Lamar's chin and the groceries
BAG_TOP, BAG_BOTTOM, BAG_L, BAG_R = 21, 32, 6, 33


def bag(p):
    for y in range(BAG_TOP, BAG_BOTTOM + 1):
        inset = (y - BAG_TOP) // 7  # sides taper slightly toward the base
        for x in range(BAG_L + inset, BAG_R - inset + 1):
            if y <= BAG_TOP + 1:
                c = BAG_RIM  # folded-over rim
            elif x in (BAG_L + inset + 4, BAG_R - inset - 4) and y > BAG_TOP + 3:
                c = BAG_SHADE  # side creases
            else:
                c = BAG
            p(x, y, c)


layer(bag, BAG_LINE)
for x in range(BAG_L + 1, BAG_R):  # crease line under the folded rim
    put(x, BAG_TOP + 2, BAG_SHADE)

# --- paws hooked over the rim (cream, with Lamar's outline colour)
CREAM, OUTLINE = (251, 247, 237), (11, 10, 10)


def paws(p):
    for px in (11, 24):
        for dx in range(4):
            for dy in range(2):
                p(px + dx, BAG_TOP - 1 + dy, CREAM)


layer(paws, OUTLINE)
for px in (11, 24):  # toe lines
    put(px + 1, BAG_TOP + 1, OUTLINE)
    put(px + 2, BAG_TOP + 1, OUTLINE)


# ------------------------------------------------------------------ export
def art(scale):
    img = Image.new('RGBA', (N * scale, N * scale), (0, 0, 0, 0))
    px = img.load()
    for y in range(N):
        for x in range(N):
            c = canvas[y][x]
            if c is None:
                continue
            for yy in range(y * scale, (y + 1) * scale):
                for xx in range(x * scale, (x + 1) * scale):
                    px[xx, yy] = (*c, 255)
    return img


def centred(scale, size=1024, bg=None):
    out = Image.new('RGBA', (size, size), (*bg, 255) if bg else (0, 0, 0, 0))
    a = art(scale)
    bbox = a.getbbox()
    a = a.crop(bbox)
    out.alpha_composite(a, ((size - a.width) // 2, (size - a.height) // 2))
    return out


os.makedirs('assets/icon', exist_ok=True)
# Full bleed: art fills ~80% of the tile.
centred(25, bg=PINK_BG).convert('RGB').save('assets/icon/icon.png')
# Adaptive foreground: launchers show only the centre ~66% (often as a circle),
# so the art must sit inside a ~600 px circle.
centred(13).save('assets/icon/icon_foreground.png')

# Preview: circle mask, squircle mask, and tiny sizes, to check legibility.
os.makedirs('build', exist_ok=True)
full = Image.open('assets/icon/icon.png').convert('RGBA')
fg = Image.open('assets/icon/icon_foreground.png')
adaptive = Image.new('RGBA', (1024, 1024), (*PINK_BG, 255))
adaptive.alpha_composite(fg)
sheet = Image.new('RGBA', (1024 * 2 + 300, 1024), (240, 240, 240, 255))
# Android adaptive icons show only the centre 72dp of the 108dp layer.
visible = round(1024 * 72 / 108)
off = (1024 - visible) // 2
adaptive = adaptive.crop((off, off, off + visible, off + visible)).resize((1024, 1024), Image.NEAREST)
for i, (img, radius) in enumerate(((adaptive, 512), (full, 230))):
    mask = Image.new('L', (1024, 1024), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=radius, fill=255)
    sheet.paste(img, (i * 1024, 0), mask)
for j, s in enumerate((192, 96, 48)):
    small = full.resize((s, s), Image.LANCZOS)
    sheet.paste(small, (2048 + 20, 20 + j * 260))
sheet.save('build/icon_preview.png')
print('wrote assets/icon/icon.png, assets/icon/icon_foreground.png, build/icon_preview.png')
