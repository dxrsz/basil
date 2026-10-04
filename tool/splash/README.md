# Splash animation

Rebuilds `assets/images/dancing_cat.gif` from `sprite_sheet.webp` (4×3 frames).

The source is AI-generated pixel art with mixels (art pixels of inconsistent
size). The pipeline snaps it back onto a clean grid:

1. `depix2.py`: maps every pixel to an 8-colour palette, then for each frame
   searches the grid size (~8 px) and offset that make grid cells the most
   single-coloured, and takes each cell's majority colour.
2. `clean.py`: merges cream/white, keeps the dark outline on the silhouette
   only, and removes lone specks and pinholes.
3. `build_gif.py`: aligns frames on head centre + feet so the cat dances in
   place, and writes a 1× GIF (39×43) for the app plus an 8× preview.
   `render.py` writes a contact sheet for eyeballing.

```bash
cd tool/splash
python3 -m venv .venv && .venv/bin/pip install pillow numpy
.venv/bin/python depix2.py && .venv/bin/python clean.py && .venv/bin/python build_gif.py
cp dancing_cat.gif ../../assets/images/
```

The app scales the 1× GIF by a whole number of physical pixels
(`lib/features/splash/splash_screen.dart`) so the pixels stay uniform.
