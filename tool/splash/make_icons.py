# Builds assets/icon/*.png from Lamar's standing frame; then run
# `dart run flutter_launcher_icons` to produce the platform icon sets.
from PIL import Image
import numpy as np

gif = Image.open('assets/images/dancing_cat.gif'); gif.seek(0)
cat = gif.convert('RGBA')
a = np.array(cat); ys, xs = np.where(a[..., 3] > 0)
cat = cat.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
w, h = cat.size
PINK = (246, 213, 206, 255)  # keep in sync with adaptive_icon_background in pubspec.yaml

def place(canvas, scale):
    big = cat.resize((w * scale, h * scale), Image.NEAREST)  # whole-number scale: crisp pixels
    canvas.alpha_composite(big, ((canvas.width - big.width) // 2, (canvas.height - big.height) // 2))
    return canvas

# Full-bleed icon (iOS, legacy Android, web): Lamar fills ~70% of the tile.
place(Image.new('RGBA', (1024, 1024), PINK), 17).convert('RGB').save('assets/icon/icon.png')
# Adaptive foreground: launchers mask to the centre ~66%, so keep him inside it.
place(Image.new('RGBA', (1024, 1024), (0, 0, 0, 0)), 13).save('assets/icon/icon_foreground.png')
