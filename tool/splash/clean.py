import numpy as np
frames = list(np.load('frames.npy', allow_pickle=True))
OUT, FUR, CREAM, WHITE, PINK, EYE, WL, WD, T = range(9)

def neighbours(g):
    p = np.pad(g, 1, constant_values=T)
    return np.stack([p[:-2,1:-1], p[2:,1:-1], p[1:-1,:-2], p[1:-1,2:]])   # up, down, left, right

cleaned=[]
for g in frames:
    g = g.copy()
    g[g == WHITE] = CREAM                       # near-identical colours -> one
    for _ in range(2):
        n = neighbours(g)
        touches_bg = (n == T).any(0)
        # outline only on the silhouette; interior "outline" specks become fur
        interior_out = (g == OUT) & ~touches_bg & ((n == FUR).sum(0) >= 3)
        g[interior_out] = FUR
        g[(g == FUR) & touches_bg] = OUT
        # lone cream/fur specks swallowed by the surrounding colour
        n = neighbours(g)
        for c in (CREAM, FUR, OUT):
            for other in (CREAM, FUR, OUT):
                if c == other: continue
                lone = (g == c) & ((n == other).sum(0) == 4)
                g[lone] = other
        # 1-pixel transparent holes inside the body
        n = neighbours(g)
        hole = (g == T) & ((n != T).sum(0) == 4)
        for c in (OUT, FUR, CREAM):
            g[hole & ((n == c).sum(0) >= 3)] = c
    cleaned.append(g)
np.save('frames_clean.npy', np.array(cleaned, dtype=object), allow_pickle=True)
