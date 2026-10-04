from PIL import Image
import numpy as np
frames = list(np.load('frames_clean.npy', allow_pickle=True))
pal = np.load('pal.npy'); T = len(pal)

anchors=[]
for g in frames:
    h = g.shape[0]
    ys, xs = np.where(g[: int(round(h*0.30))] != T)
    anchors.append(int(round(xs.mean())))          # head centre column
left  = max(a for a in anchors)
right = max(g.shape[1]-a for g,a in zip(frames,anchors))
H = max(g.shape[0] for g in frames)
pad = 1
W = left + right + 2*pad; H += 2*pad
print('canvas cells', W, 'x', H)

palette = [int(v) for c in pal for v in c] + [255,0,255]   # index T = transparent
palette += [0]*(768-len(palette))
def make(scale):
    out=[]
    for g,a in zip(frames,anchors):
        c = np.full((H, W), T, np.uint8)
        y = H - pad - g.shape[0]; x = pad + left - a
        c[y:y+g.shape[0], x:x+g.shape[1]] = g
        im = Image.fromarray(c, 'P'); im.putpalette(palette)
        if scale > 1: im = im.resize((W*scale, H*scale), Image.NEAREST)
        out.append(im)
    return out
for scale, name in [(1, 'dancing_cat.gif'), (8, 'dancing_cat_preview.gif')]:
    fr = make(scale)
    fr[0].save(name, save_all=True, append_images=fr[1:], duration=130, loop=0,
               disposal=2, transparency=T, optimize=False)
import os; print({n: os.path.getsize(n) for n in ['dancing_cat.gif','dancing_cat_preview.gif']})
