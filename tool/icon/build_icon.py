"""Builds the app icon from two AI-made pixel-art layers, de-mixeled.

Inputs (tool/icon/): background.webp (green glow, leaves, sparkles) and
foreground.webp (Lamar in a grocery bag, transparent).
Each is snapped onto a uniform pixel grid (snap.py) and cleaned of stray
specks, then written as:
  assets/icon/icon_background.png   Android adaptive background (full bleed)
  assets/icon/icon_foreground.png   Android adaptive foreground (fits the circle)
  assets/icon/icon.png              iOS / web / legacy: both layers flattened
and build/icon_preview.png (circle / squircle / small sizes). Then run
`dart run flutter_launcher_icons`.

    tool/splash/.venv/bin/python tool/icon/build_icon.py   (from the repo root)
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(__file__))
from snap import palette_labels, render, snap  # noqa: E402

HERE = os.path.dirname(__file__)
SIZE = 1024
# Lamar's size: whole-number pixel scales.
FG_SCALE = int(os.environ.get('FG_SCALE', 11))      # Android foreground (visible circle ~683 px)
FLAT_SCALE = int(os.environ.get('FLAT_SCALE', 14))  # flattened iOS/web icon
FG_DY = int(os.environ.get('FG_DY', 0))  # nudge the Android foreground down (px)


def despeckle(g: np.ndarray) -> np.ndarray:
    """Single cells whose four neighbours all share another colour take that colour."""
    g = g.copy()
    for _ in range(2):
        p = np.pad(g, 1, constant_values=-1)
        n = np.stack([p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:]])
        same = (n == n[0]).all(0) & (n[0] != g)
        g[same] = n[0][same]
    return g


def trim(g: np.ndarray) -> np.ndarray:
    ys, xs = np.where(g >= 0)
    return g[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


# Background: a clean 64x64 grid (19.6 px cells in the 1254 px source).
lab, pal_bg = palette_labels(Image.open(os.path.join(HERE, 'background.webp')), 10)
bg, _, _ = snap(lab, 10, 19.6)
bg = despeckle(trim(bg))[:64, :64]
assert bg.shape == (64, 64) and (bg >= 0).all(), bg.shape
background = render(bg, pal_bg, SIZE // 64)                       # 64 * 16 = 1024

# Lamar: no single clean grid in the source; 14 px cells keep his smile and eyes.
labf, pal_fg = palette_labels(Image.open(os.path.join(HERE, 'foreground.webp')), 28)
fg, _, _ = snap(labf, 28, 14.0)
fg = trim(despeckle(fg))


def centred(cells: np.ndarray, scale: int, dy: int = 0) -> Image.Image:
    art = render(cells, pal_fg, scale)
    out = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(art, ((SIZE - art.width) // 2, (SIZE - art.height) // 2 + dy), art)  # paste clips at the edge
    return out


os.makedirs('assets/icon', exist_ok=True)
# Adaptive background: launchers only show the centre 72/108, which would crop
# the leaves and sparkles away. Draw the art smaller (11 px cells, 704 px) in
# the middle and extend its edge colours outwards to fill the 1024 layer.
pad = 15  # cells: (1024 - 64 * 11) / 2 / 11 ≈ 14.5
adaptive_bg = render(np.pad(bg, pad, mode='edge'), pal_bg, 11)
c = (adaptive_bg.width - SIZE) // 2
adaptive_bg = adaptive_bg.crop((c, c, c + SIZE, c + SIZE))
adaptive_bg.convert('RGB').save('assets/icon/icon_background.png')
# Adaptive foreground: launchers show the centre 72/108 of the layer, usually
# masked to a circle (~683 px here); Lamar fills most of it.
centred(fg, FG_SCALE, dy=FG_DY).save('assets/icon/icon_foreground.png')  # ears just inside the circle; the bag's bottom may clip
# Flattened icon: Lamar large on the glow.
flat = background.copy()
flat.alpha_composite(centred(fg, FLAT_SCALE))
flat.convert('RGB').save('assets/icon/icon.png')

# Preview: Android circle (what launchers show), iOS squircle, small sizes.
os.makedirs('build', exist_ok=True)
adaptive = adaptive_bg.copy()
adaptive.alpha_composite(Image.open('assets/icon/icon_foreground.png'))
visible = round(SIZE * 72 / 108)
off = (SIZE - visible) // 2
adaptive = adaptive.crop((off, off, off + visible, off + visible)).resize((SIZE, SIZE), Image.NEAREST)
sheet = Image.new('RGBA', (SIZE * 2 + 300, SIZE), (240, 240, 240, 255))
for i, (img, radius) in enumerate(((adaptive, 512), (flat, 230))):
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=radius, fill=255)
    sheet.paste(img, (i * SIZE, 0), mask)
for j, s in enumerate((192, 96, 48)):
    sheet.paste(flat.resize((s, s), Image.LANCZOS), (2 * SIZE + 20, 20 + j * 260))
sheet.save('build/icon_preview.png')
print('lamar cells', fg.shape, '-> wrote assets/icon/*.png and build/icon_preview.png')
