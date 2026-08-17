"""Derive the launcher-icon sources from assets/logo.jpeg.

Two outputs, because Android wants two different things:

  * `tera_icon.png`      — the square legacy icon: the logo on its own white ground.
  * `tera_icon_fg.png`   — the adaptive-icon foreground: the artwork alone, on transparency,
                           scaled to fit the adaptive safe zone.

Why the foreground has to be generated rather than pointing flutter_launcher_icons at the JPEG:

  1. **A JPEG has no alpha.** Used as an adaptive foreground it paints an opaque white square over
     the whole canvas, which hides `adaptive_icon_background` entirely — the background colour
     would be configured and never seen.
  2. **The artwork reaches the corners of its bounding box.** Measured: a true enclosing radius of
     525 px against a bounding-box half-diagonal of 527, so the "T" and "A" of the wordmark and the
     ECG dot sit right at the extremes. An adaptive icon is masked to a 72dp circle inside a 108dp
     canvas, so anything outside the centre 66.7% is cut. Dropped in at full bleed, the wordmark
     loses its outer letters on any launcher using a circular mask.

The foreground is therefore scaled so the artwork's enclosing *circle* fits the safe circle, which
is the only fit that survives every mask shape.
"""

import math
from PIL import Image, ImageChops

SRC = 'assets/logo.jpeg'
CANVAS = 1024

# Android reserves the outer 18dp of the 108dp adaptive canvas, leaving 72dp visible, and a
# circular mask inscribes that. 72/108 = 0.667, so the safe radius is a third of the canvas.
#
# **flutter_launcher_icons then insets this drawable by a further 16% per edge** — see the
# generated `mipmap-anydpi-v26/ic_launcher.xml` — so the artwork ends up at 68% of whatever it is
# scaled to here. Padding to the safe radius in this file as well would double-pad it: the first
# run produced an effective radius of 0.22 against a safe 0.33, which is a correct icon that looks
# lost in its own canvas. This is therefore pre-compensated: 0.47 x 0.68 = 0.32, landing just
# inside the safe circle after the generator has had its turn.
GENERATOR_INSET = 0.16
SAFE_RADIUS_FRACTION = 0.32 / (1 - 2 * GENERATOR_INSET)

# The legacy icon is not masked as aggressively (and with minSdk 26 it is mostly a fallback), so it
# can carry the artwork larger.
LEGACY_RADIUS_FRACTION = 0.40


def artwork_and_radius(im):
    """The trimmed artwork, and the radius of the smallest circle centred on it that contains it."""
    white = Image.new('RGB', im.size, (255, 255, 255))
    diff = ImageChops.difference(im, white).convert('L')
    mask = diff.point(lambda v: 255 if v > 24 else 0)
    bbox = mask.getbbox()

    px = mask.load()
    x0, y0, x1, y1 = bbox
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    radius = max(
        math.hypot(x - cx, y - cy)
        for y in range(y0, y1, 2)
        for x in range(x0, x1, 2)
        if px[x, y]
    )
    return bbox, radius


def scaled(im, bbox, radius, target_radius):
    """The artwork cropped to `bbox` and scaled so its enclosing radius becomes `target_radius`."""
    factor = target_radius / radius
    crop = im.crop(bbox)
    size = (max(1, round(crop.width * factor)), max(1, round(crop.height * factor)))
    return crop.resize(size, Image.LANCZOS)


def main():
    im = Image.open(SRC).convert('RGB')
    bbox, radius = artwork_and_radius(im)
    print(f'source {im.size}, artwork bbox {bbox}, enclosing radius {radius:.1f}')

    # --- adaptive foreground: artwork on transparency ---
    art = scaled(im, bbox, radius, CANVAS * SAFE_RADIUS_FRACTION)
    # The ground is white, so anything near-white becomes transparent and the navy survives. A
    # per-pixel alpha from the luminance keeps the antialiased edges soft rather than jagged.
    grey = art.convert('L')
    alpha = grey.point(lambda v: 0 if v > 244 else min(255, int((244 - v) * 255 / 96)))
    art_rgba = art.convert('RGBA')
    art_rgba.putalpha(alpha)

    fg = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    fg.paste(
        art_rgba,
        ((CANVAS - art_rgba.width) // 2, (CANVAS - art_rgba.height) // 2),
        art_rgba,
    )
    fg.save('assets/icon/tera_icon_fg.png')
    print(f'foreground: artwork {art_rgba.size} on {CANVAS}px transparent canvas')

    # --- legacy square icon: artwork on the brand's own white ground ---
    legacy_art = scaled(im, bbox, radius, CANVAS * LEGACY_RADIUS_FRACTION)
    legacy = Image.new('RGB', (CANVAS, CANVAS), (255, 255, 255))
    legacy.paste(
        legacy_art,
        ((CANVAS - legacy_art.width) // 2, (CANVAS - legacy_art.height) // 2),
    )
    legacy.save('assets/icon/tera_icon.png')
    print(f'legacy: artwork {legacy_art.size} on {CANVAS}px white canvas')


if __name__ == '__main__':
    main()
