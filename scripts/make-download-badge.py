#!/usr/bin/env python3
# Writes docs/download-macos-dark.png and docs/download-macos-light.png,
# the 3x "Download app for macOS" badges at the top of README.md.
#
#   scripts/make-download-badge.py
#
# Needs Pillow (pip install pillow).
import os
from PIL import Image, ImageDraw, ImageFont

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SF_COMPACT = "/System/Library/Fonts/SFCompact.ttf"
SF_NS = "/System/Library/Fonts/SFNS.ttf"

# Reference proportions are in 386 x 129 units; draw at 6x and downsample to 3x.
REF_W, REF_H = 386.0, 129.0
W, H = 152, 51
S = 6

THEMES = {
    "dark": {
        "bg": (0, 0, 0, 255),
        "fg": (255, 255, 255, 255),
        "border": (182, 182, 182, 255),
    },
    "light": {
        "bg": (255, 255, 255, 255),
        "fg": (0, 0, 0, 255),
        "border": (166, 166, 166, 255),
    },
}


def draw_tracked(draw, pos, text, font, fill, tracking):
    x, y = pos
    prev = ""
    for ch in text:
        if prev:
            kern = font.getlength(prev + ch) - font.getlength(prev) - font.getlength(ch)
            x += kern + tracking
        draw.text((x, y), ch, font=font, fill=fill)
        x += font.getlength(ch)
        prev = ch


def render(theme):
    colors = THEMES[theme]
    cw, ch = W * S, H * S
    sx = cw / REF_W
    sy = ch / REF_H
    sc = (sx + sy) / 2.0

    img = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    d.rounded_rectangle(
        (0, 0, cw - 1, ch - 1),
        radius=19.8 * sc,
        fill=colors["bg"],
        outline=colors["border"],
        width=max(1, round(2.6 * sc)),
    )

    f_apple = ImageFont.truetype(SF_NS, 94.0 * sc)
    ab = f_apple.getbbox("\uf8ff")
    d.text((27.25 * sx - ab[0], 27.25 * sy - ab[1]), "\uf8ff", font=f_apple, fill=colors["fg"])

    f_sub = ImageFont.truetype(SF_COMPACT, 29.0 * sc)
    f_sub.set_variation_by_axes([20, 400, 425])
    db = f_sub.getbbox("D")
    draw_tracked(
        d,
        (135.0 * sx - db[0], 26.25 * sy - db[1]),
        "Download app for",
        f_sub,
        colors["fg"],
        -0.58 * sx,
    )

    f_title = ImageFont.truetype(SF_COMPACT, 61.5 * sc)
    f_title.set_variation_by_axes([20, 400, 555])
    mb = f_title.getbbox("m")
    ob = f_title.getbbox("O")
    draw_tracked(
        d,
        (164.0 * sx - mb[0], 57.0 * sy - ob[1]),
        "macOS",
        f_title,
        colors["fg"],
        -1.2 * sx,
    )

    return img.resize((W * 3, H * 3), Image.LANCZOS)


for name in THEMES:
    out_path = os.path.join(root, "docs", f"download-macos-{name}.png")
    render(name).save(out_path, optimize=True)
