"""Snaps AI pixel art (mixels, soft edges) onto a uniform pixel grid.

For a given cell size P, it searches the grid offset that makes cells most
single-coloured (after fitting a palette), then gives each cell its majority
colour. Returns (grid of palette indices, palette); -1 = transparent.
"""
import numpy as np
from PIL import Image
from sklearn.cluster import MiniBatchKMeans


def palette_labels(img: Image.Image, k: int):
    a = np.array(img.convert('RGBA')).astype(np.int32)
    opaque = a[..., 3] >= 128
    km = MiniBatchKMeans(n_clusters=k, n_init=4, random_state=0, batch_size=8192)
    km.fit(a[..., :3][opaque][::5].astype(float))
    lab = np.full(opaque.shape, k, dtype=np.int64)          # k = transparent
    lab[opaque] = km.predict(a[..., :3][opaque].astype(float))
    pal = np.clip(np.round(km.cluster_centers_), 0, 255).astype(np.uint8)
    return lab, pal


def snap(lab: np.ndarray, k: int, P: float, step: float = 1.0):
    h, w = lab.shape
    nl = k + 1
    best = (-1.0, 0.0, 0.0)
    for ox in np.arange(0, P, step):
        cx = np.floor((np.arange(w) - ox) / P).astype(int) + 1
        for oy in np.arange(0, P, step):
            cy = np.floor((np.arange(h) - oy) / P).astype(int) + 1
            nx, ny = cx.max() + 1, cy.max() + 1
            cell = (cy[:, None] * nx + cx[None, :]).ravel()
            hist = np.bincount(cell * nl + lab.ravel(), minlength=ny * nx * nl).reshape(-1, nl)
            tot = hist.sum(1)
            occ = tot > 0
            purity = hist.max(1)[occ].sum() / tot[occ].sum()
            if purity > best[0]:
                best = (purity, ox, oy)
    purity, ox, oy = best
    cx = np.floor((np.arange(w) - ox) / P).astype(int) + 1
    cy = np.floor((np.arange(h) - oy) / P).astype(int) + 1
    nx, ny = cx.max() + 1, cy.max() + 1
    cell = (cy[:, None] * nx + cx[None, :]).ravel()
    hist = np.bincount(cell * nl + lab.ravel(), minlength=ny * nx * nl).reshape(ny * nx, nl)
    g = hist.argmax(1)
    g[hist.sum(1) == 0] = k
    g = g.reshape(ny, nx)
    g[g == k] = -1
    return g, purity, (ox, oy)


def render(g: np.ndarray, pal: np.ndarray, scale: int, bg=None) -> Image.Image:
    h, w = g.shape
    out = np.zeros((h, w, 4), np.uint8)
    m = g >= 0
    out[m, :3] = pal[g[m]]
    out[m, 3] = 255
    im = Image.fromarray(out, 'RGBA').resize((w * scale, h * scale), Image.NEAREST)
    if bg is not None:
        base = Image.new('RGBA', im.size, bg)
        base.alpha_composite(im)
        im = base
    return im
