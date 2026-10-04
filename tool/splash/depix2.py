from PIL import Image
import numpy as np

A = np.array(Image.open('sprite_sheet.webp').convert('RGBA')).astype(int)
pal = np.array([[11,10,10],[26,26,26],[251,247,237],[253,251,246],[242,147,134],
                [196,198,57],[207,200,201],[111,102,104]])
idx = ((A[...,None,:3]-pal[None,None])**2).sum(-1).argmin(-1)
lab = np.where(A[...,3] > 128, idx, len(pal))   # 8 = transparent
NL = len(pal)+1
boxes = [(32,78,263,409),(354,78,587,408),(638,78,930,409),(959,86,1221,409),
         (50,463,297,785),(340,460,594,785),(679,466,921,784),(985,451,1237,784),
         (35,849,317,1169),(328,841,609,1168),(665,850,938,1175),(993,849,1237,1175)]

def snap(L, P, ox, oy):
    h, w = L.shape
    cy = np.floor((np.arange(h)-oy)/P).astype(int) + 1
    cx = np.floor((np.arange(w)-ox)/P).astype(int) + 1
    ny, nx = cy.max()+1, cx.max()+1
    cell = (cy[:,None]*nx + cx[None,:]).ravel()
    hist = np.bincount(cell*NL + L.ravel(), minlength=ny*nx*NL).reshape(ny*nx, NL)
    # ignore cells that are wholly transparent when scoring
    occ = hist[:, :-1].sum(1) > 0
    purity = hist.max(1)[occ].sum() / hist[occ].sum()
    g = hist.argmax(1)
    g[hist.sum(1) == 0] = NL-1     # cells with no pixels are transparent
    return purity, g.reshape(ny, nx)

frames=[]
for (x0,y0,x1,y1) in boxes:
    pad=10
    L = lab[y0-pad:y1+pad, x0-pad:x1+pad]
    best=(0,)
    for P in np.arange(8.0, 9.3, 0.1):
        for ox in np.arange(0, P, 0.5):
            for oy in np.arange(0, P, 0.5):
                pur,_ = snap(L,P,ox,oy)
                if pur > best[0]: best=(pur,P,ox,oy)
    pur,P,ox,oy = best
    _, g = snap(L,P,ox,oy)
    ys,xs = np.where(g < NL-1)
    g = g[ys.min():ys.max()+1, xs.min():xs.max()+1]
    print(f'P={P:.1f} off=({ox:.1f},{oy:.1f}) purity={pur:.3f} cells={g.shape[1]}x{g.shape[0]}')
    frames.append(g)

np.save('frames.npy', np.array(frames, dtype=object), allow_pickle=True)
np.save('pal.npy', pal)
