import sys
from PIL import Image
import numpy as np
frames = np.load(sys.argv[1] if len(sys.argv)>1 else 'frames.npy', allow_pickle=True)
pal = np.load('pal.npy'); NL = len(pal)+1
S = 8
def img(g):
    rgba = np.zeros(g.shape+(4,), np.uint8)
    m = g < NL-1
    rgba[m,:3] = pal[g[m]]; rgba[m,3] = 255
    return Image.fromarray(rgba).resize((g.shape[1]*S, g.shape[0]*S), Image.NEAREST)
W = max(f.shape[1] for f in frames)*S + 20; H = max(f.shape[0] for f in frames)*S + 20
prev = Image.new('RGB', (W*6, H*2), (251,250,246))
for i,g in enumerate(frames):
    im = img(g); prev.paste(im, ((i%6)*W+10, (i//6)*H+10), im)
prev.save('preview2.png')
img(frames[0]).crop((0,0,180,180)).resize((540,540), Image.NEAREST).save('zoom2.png')
