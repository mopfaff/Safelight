#!/usr/bin/env python3
# Writes the pictures for the r/coolgithubprojects gallery to build/reddit/coolgithubprojects/, from the
# README's screenshots in docs/ (scripts/screenshots.sh draws those). The README's copies are see-through
# around the window, and Reddit would fill that with a colour of its own, so each is put on a ground of
# its appearance: black for Dark, a light grey for Light.
#
#   scripts/make-reddit-pictures.py
#
#   1-popover.png, 1-popover-light.png          the popover, 2256 × 1355 like the Schedule's
#   2-schedule.png, 2-schedule-light.png        the Schedule window
#   1-popover-portrait(-light).png              the popover on a 4:5 ground, 1080 × 1350
#   1-popover-portrait-no-clock(-light).png     the same without the menu bar's clock, so the popover
#                                               itself is in the middle rather than it and the clock
#
# Needs Pillow (pip install pillow).
import io, os
from PIL import Image, ImageCms

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
docs = os.path.join(root, "docs")
out = os.path.join(root, "build", "reddit", "coolgithubprojects")
LANDSCAPE, PORTRAIT = (2256, 1355), (1080, 1350)
GROUND = {"dark": (0, 0, 0), "light": (233, 233, 238)}
# In docs/popover-*.png: the popover's sides, and where the clock is in the menu bar above it
POPOVER_LEFT, POPOVER_RIGHT = 46, 681
CLOCK_LEFT, CLOCK_BOTTOM = 600, 48

def srgb(name):  # the screenshots are in Display P3; Reddit's pictures are drawn as sRGB
    image = Image.open(os.path.join(docs, name)).convert("RGBA")
    p3 = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
    return ImageCms.profileToProfile(image, p3, ImageCms.createProfile("sRGB"), outputMode="RGBA")

def without_clock(popover):
    """The popover's screenshot with the clock gone. The popover's shadow reaches up behind the clock,
    so that corner is filled with the shadow's other side, mirrored, rather than cleared."""
    popover = popover.copy()
    centre = POPOVER_LEFT + POPOVER_RIGHT  # twice the popover's centre: x mirrors to centre - x
    width = popover.width - CLOCK_LEFT
    patch = Image.new("RGBA", (width, CLOCK_BOTTOM), (0, 0, 0, 0))
    left = centre - (popover.width - 1)  # where the mirrored strip begins, maybe off the picture's left
    source = popover.crop((max(left, 0), 0, centre - CLOCK_LEFT + 1, CLOCK_BOTTOM)).transpose(Image.FLIP_LEFT_RIGHT)
    patch.paste(source, (0, 0))
    popover.paste(patch, (CLOCK_LEFT, 0))
    return popover

def write(name, picture, size, appearance, centre_x=None):
    """`picture` in the middle of a ground of `size`, or with its column `centre_x` in the middle"""
    canvas = Image.new("RGBA", size, GROUND[appearance] + (255,))
    x = (size[0] - picture.width) // 2 if centre_x is None else round(size[0] / 2 - centre_x)
    canvas.alpha_composite(picture, (x, (size[1] - picture.height) // 2))
    canvas.convert("RGB").save(os.path.join(out, name), optimize=True)

os.makedirs(out, exist_ok=True)
for appearance, suffix in (("dark", ""), ("light", "-light")):
    popover, schedule = srgb(f"popover-{appearance}.png"), srgb(f"schedule-{appearance}.png")
    write(f"1-popover{suffix}.png", popover, LANDSCAPE, appearance)
    write(f"2-schedule{suffix}.png", schedule, LANDSCAPE, appearance)
    write(f"1-popover-portrait{suffix}.png", popover, PORTRAIT, appearance)
    write(f"1-popover-portrait-no-clock{suffix}.png", without_clock(popover), PORTRAIT, appearance,
          centre_x=(POPOVER_LEFT + POPOVER_RIGHT + 1) / 2)
print(f"Wrote 8 pictures to {os.path.relpath(out, os.getcwd())}")
