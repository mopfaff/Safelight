#!/usr/bin/env python3
# Writes docs/download-macos.png, the 3x "Download for macOS" badge at the top of README.md.
#
#   scripts/make-download-badge.py
#
# Needs Pillow (pip install pillow).
import os
from PIL import Image, ImageDraw, ImageFont

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
out_path = os.path.join(root, "docs", "download-macos.png")
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


# Draw at 6x and downsample to 3x for crisp antialiasing
S = 6
W, H = 152, 52
img = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

pad = round(0.75 * S)
d.rounded_rectangle(
    (pad, pad, W * S - pad - 1, H * S - pad - 1),
    radius=10 * S,
    fill=(14, 15, 18, 255),
    outline=(158, 160, 168, 220),
    width=round(1.15 * S),
)

# Download icon (filled circle with downward arrow cut out)
cx, cy = 29 * S, (H / 2) * S
r = 13 * S
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))

ink = (14, 15, 18, 255)
sw = round(2.4 * S)
cap = sw / 2
d.line([(cx, cy - 6.4 * S), (cx, cy + 5.0 * S)], fill=ink, width=sw)
d.ellipse((cx - cap, cy - 6.4 * S - cap, cx + cap, cy - 6.4 * S + cap), fill=ink)
pts = [
    (cx - 5.0 * S, cy + 0.8 * S),
    (cx, cy + 5.8 * S),
    (cx + 5.0 * S, cy + 0.8 * S),
]
d.line(pts, fill=ink, width=sw, joint="curve")
for px, py in pts:
    d.ellipse((px - cap, py - cap, px + cap, py + cap), fill=ink)

tx = 53 * S
d.text((tx, 8.5 * S), "Download for", font=font(11.5 * S, "Regular"), fill=(224, 226, 232, 255))
d.text((tx - 0.5 * S, 20.5 * S), "macOS", font=font(22.5 * S, "Semibold"), fill=(255, 255, 255, 255))

img.resize((W * 3, H * 3), Image.LANCZOS).save(out_path, optimize=True)
