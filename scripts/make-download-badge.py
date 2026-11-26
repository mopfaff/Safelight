#!/usr/bin/env python3
# Writes docs/download-macos-dark.png and docs/download-macos-light.png,
# the 3x "Download app for macOS" badges at the top of README.md, using
# Icon Composer's ictool so their edges carry macOS's native light and shadow
# effect, matching docs/icon.png.
#
#   scripts/make-download-badge.py
#
# Needs Xcode (Icon Composer's ictool) and Pillow (pip install pillow).
import json
import os
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFont

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SF_COMPACT = "/System/Library/Fonts/SFCompact.ttf"
SF_NS = "/System/Library/Fonts/SFNS.ttf"
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

# Reference proportions are in 386 x 129 units; draw foreground at 6x and downsample to 3x.
REF_W, REF_H = 386.0, 129.0
W, H = 152, 51
S = 6


def srgb(r, g, b):
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


THEMES = {
    "dark": {
        "fill": "system-dark",
        "fg": (255, 255, 255, 255),
        "hairline": None,
    },
    "light": {
        # Soft off-white gradient so the bright white top/bottom specular light and
        # darker left/right edge shadows stay visible inside a subtle hairline on white pages.
        "fill": {"linear-gradient": [srgb(0.95, 0.95, 0.96), srgb(0.88, 0.88, 0.90)]},
        "fg": (0, 0, 0, 255),
        "hairline": (2, 0.20),  # (inset_px at 3x, black alpha)
    },
}


def render_ictool_rect(fill, w_px, h_px):
    with tempfile.TemporaryDirectory() as tmp:
        icon_dir = os.path.join(tmp, "badge.icon")
        os.makedirs(icon_dir)
        doc = {
            "fill": fill,
            "groups": [],
            "supported-platforms": {"squares": ["macOS"]},
        }
        with open(os.path.join(icon_dir, "icon.json"), "w") as f:
            json.dump(doc, f)
        out = os.path.join(tmp, "out.png")
        subprocess.run(
            [
                ICTOOL,
                icon_dir,
                "--export-image",
                "--output-file",
                out,
                "--platform",
                "macOS",
                "--rendition",
                "Default",
                "--width",
                str(w_px),
                "--height",
                str(h_px),
                "--scale",
                "1",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        return Image.open(out).convert("RGBA")


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


def render_foreground(fg):
    cw, ch = W * S, H * S
    sx = cw / REF_W
    sy = ch / REF_H
    sc = (sx + sy) / 2.0

    img = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    f_apple = ImageFont.truetype(SF_NS, 94.0 * sc)
    ab = f_apple.getbbox("\uf8ff")
    d.text((27.25 * sx - ab[0], 27.25 * sy - ab[1]), "\uf8ff", font=f_apple, fill=fg)

    f_sub = ImageFont.truetype(SF_COMPACT, 29.0 * sc)
    f_sub.set_variation_by_axes([20, 400, 425])
    db = f_sub.getbbox("D")
    draw_tracked(
        d,
        (135.0 * sx - db[0], 26.25 * sy - db[1]),
        "Download app for",
        f_sub,
        fg,
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
        fg,
        -1.2 * sx,
    )

    return img.resize((W * 3, H * 3), Image.LANCZOS)


def render(theme):
    spec = THEMES[theme]
    w3, h3 = W * 3, H * 3
    if spec["hairline"] is None:
        img = render_ictool_rect(spec["fill"], w3, h3)
    else:
        inset, alpha = spec["hairline"]
        outer_mask = render_ictool_rect(spec["fill"], w3, h3).split()[3]
        inner = render_ictool_rect(spec["fill"], w3 - 2 * inset, h3 - 2 * inset)
        img = Image.new("RGBA", (w3, h3), (0, 0, 0, 0))
        border = Image.new("RGBA", (w3, h3), (0, 0, 0, 0))
        border.putalpha(outer_mask.point(lambda v: round(v * alpha)))
        img.alpha_composite(border)
        img.alpha_composite(inner, (inset, inset))

    img.alpha_composite(render_foreground(spec["fg"]))
    return img


for name in THEMES:
    out_path = os.path.join(root, "docs", f"download-macos-{name}.png")
    render(name).save(out_path, optimize=True)
