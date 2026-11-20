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
#   1-popover-centred(-light).png and           with the clock, but the popover itself in the middle, so
#   1-popover-portrait-centred(-light).png      the clock reaches further to the right than the icon is
#                                               from the left
#   1-popover-desktop(-light).png,              over a desktop, as on screen: the wallpapers the demo has,
#   1-popover-portrait-desktop(-light).png and  Sonoma Horizon in Light and Sonoma's Dark picture in Dark,
#   2-schedule-desktop(-light).png              with the popover's glass drawn over them. These are from
#                                               the pictures `scripts/screenshots.sh --desktop` takes
#                                               (in build/screenshots/out/), and are left out without them.
#   1-popover-portrait-desktop-tight(-light).png
#                                               the portrait one with 21 pixels off each side, 1038 × 1350,
#                                               so the clock is as far from the right edge as it is on a
#                                               Mac's screen: its last digit 24 points from it
#   …-desktop-dome(-light).png                  the same four with Dome as Dark's wallpaper, from the
#                                               pictures `DARK_WALLPAPER=build/wallpapers/Dome.heic
#                                               scripts/screenshots.sh --desktop` takes (in
#                                               build/screenshots/out-dome/)
#   1-popover(-portrait)-desktop…-split.png      the popover over a desktop, the left of a slanted line with
#                                               the color filter the popover shows on (red, at 0.9) as
#                                               the screen shows it, and the right as the screenshot has
#                                               it: no screenshot has the filter in it, as macOS applies
#                                               it after the frame is drawn. The filter is the demo
#                                               videos' (scripts/demo/pipeline.py): macOS's own matrix,
#                                               multiplying light. The brightness isn't applied.
#   1-popover-desktop…-split-5x4.png            the landscape -split picture cut off 24 points right of the
#                                               clock, 1647 × 1355 (about 5:4): the desktop left of the
#                                               popover stays in it to show the filter, as Dome's rock
#                                               does, and the popover is large enough to read on a phone
#   …-split-labelled.png and                   the -split pictures with "Filter on" and "Filter off" written
#   …-split-5x4-labelled.png                    below the popover, on either side of the line, so the
#                                               halves are known for what they are at first sight
#
# Needs Pillow (pip install pillow), and for the -split pictures NumPy and PyObjC as well.
import io, os, sys
from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
docs = os.path.join(root, "docs")
out = os.path.join(root, "build", "reddit", "coolgithubprojects")
# Where the pictures over a desktop are, by what their names here end in
DESKTOPS = {"": os.path.join(root, "build", "screenshots", "out"), "-dome": os.path.join(root, "build", "screenshots", "out-dome")}
LANDSCAPE, PORTRAIT = (2256, 1355), (1080, 1350)
GROUND = {"dark": (0, 0, 0), "light": (233, 233, 238)}
# In docs/popover-*.png: the popover's sides, and where the clock is in the menu bar above it
POPOVER_LEFT, POPOVER_RIGHT = 46, 681
CLOCK_LEFT, CLOCK_BOTTOM = 600, 48
# Over a desktop 540 points wide the clock's last digit is 69 pixels from the right edge, and on a Mac's
# screen 24 points, 48 pixels; taken off both sides, the popover stays in the middle
TIGHTER = 21
# Over a desktop 1128 points wide the clock's last digit ends at pixel 1599; the -5x4 pictures end 24
# points right of it
FIVE_FOUR = 1599 + 48
# The color filter scripts/screenshots/main.swift sets for the popover: (hue, intensity)
TINT = (0, 0.90)
# How far the -split pictures' line leans: its top this many pixels right of the middle, its bottom left
LEAN = 150
# The -labelled pictures' words: in the menu bar's font, 17 points, their middle this far above the bottom
# (halfway between the popover and the bottom edge), and each this far from the line
LABELS, LABEL_FONT, LABEL_SIZE, LABEL_UP, LABEL_GAP = ("Filter on", "Filter off"), "/System/Library/Fonts/SFNS.ttf", 34, 66, 40

def srgb(name, folder=docs):  # the screenshots are in Display P3; Reddit's pictures are drawn as sRGB
    image = Image.open(os.path.join(folder, name)).convert("RGBA")
    p3 = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
    return ImageCms.profileToProfile(image, p3, ImageCms.createProfile("sRGB"), outputMode="RGBA")

def split(taken, folder):
    """A picture taken over a desktop, in sRGB, with the color filter on to the left of a slanted line
    through its middle."""
    import numpy as np
    sys.path.insert(0, os.path.join(root, "scripts", "demo"))
    import pipeline
    image = Image.open(os.path.join(folder, taken))
    display = pipeline.Display("screenshot", pipeline.BACKLIGHT, pipeline.Profile(image.info["icc_profile"]))
    frame = np.asarray(image.convert("RGB"), np.float64) / 255
    on = pipeline.to_video(pipeline.shown(frame, display, tint=TINT), display, "srgb")
    off = np.asarray(srgb(taken, folder).convert("RGB"))
    width, height = image.size
    mask = Image.new("L", (width * 4, height * 4), 0)  # drawn four times the size for a smooth edge
    ImageDraw.Draw(mask).polygon([(0, 0), (width * 2 + LEAN * 4, 0), (width * 2 - LEAN * 4, height * 4), (0, height * 4)], fill=255)
    mask = np.asarray(mask.resize((width, height), Image.LANCZOS), np.float64)[..., None] / 255
    return Image.fromarray(np.round(on * mask + off * (1 - mask)).astype(np.uint8))

def labelled(picture, whole):
    """A -split picture, or a cut of one that has its left edge, with the halves' names written on either
    side of the line. `whole` is the size of the picture the line was drawn through."""
    font = ImageFont.truetype(LABEL_FONT, LABEL_SIZE)
    font.set_variation_by_name("Semibold")
    y = picture.height - LABEL_UP
    line = whole[0] / 2 + LEAN - 2 * LEAN * y / whole[1]
    places = (((line - LABEL_GAP, y), "rm"), ((line + LABEL_GAP, y), "lm"))
    # A soft shadow under the words, so they are as clear over Light's bright desktop as over Dark's
    shadow = Image.new("L", picture.size, 0)
    for label, (place, anchor) in zip(LABELS, places):
        ImageDraw.Draw(shadow).text(place, label, font=font, anchor=anchor, fill=150)
    picture = Image.composite(Image.new("RGB", picture.size, (0, 0, 0)), picture, shadow.filter(ImageFilter.GaussianBlur(6)))
    for label, (place, anchor) in zip(LABELS, places):
        ImageDraw.Draw(picture).text(place, label, font=font, anchor=anchor, fill=(255, 255, 255))
    return picture

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

# A picture taken over a desktop, already whole: (its name there, its name here, its size here)
OVER_DESKTOP = [("popover-{}-desktop-1128x678.png", "1-popover-desktop{}.png", LANDSCAPE),
                ("popover-{}-desktop-540x675.png", "1-popover-portrait-desktop{}.png", PORTRAIT),
                ("schedule-{}-desktop-1128x678.png", "2-schedule-desktop{}.png", LANDSCAPE)]

os.makedirs(out, exist_ok=True)
count, missing = 0, []
for appearance, suffix in (("dark", ""), ("light", "-light")):
    popover, schedule = srgb(f"popover-{appearance}.png"), srgb(f"schedule-{appearance}.png")
    write(f"1-popover{suffix}.png", popover, LANDSCAPE, appearance)
    write(f"2-schedule{suffix}.png", schedule, LANDSCAPE, appearance)
    write(f"1-popover-portrait{suffix}.png", popover, PORTRAIT, appearance)
    middle = (POPOVER_LEFT + POPOVER_RIGHT + 1) / 2
    write(f"1-popover-portrait-no-clock{suffix}.png", without_clock(popover), PORTRAIT, appearance, centre_x=middle)
    write(f"1-popover-centred{suffix}.png", popover, LANDSCAPE, appearance, centre_x=middle)
    write(f"1-popover-portrait-centred{suffix}.png", popover, PORTRAIT, appearance, centre_x=middle)
    count += 6
    for wallpaper, desktops in DESKTOPS.items():
        for taken, name, size in OVER_DESKTOP:
            name = name.format(wallpaper + suffix)
            if not os.path.exists(os.path.join(desktops, taken.format(appearance))):
                missing.append(name)
                continue
            # The points are whole, so the landscape one is a row of pixels taller than the Schedule's
            srgb(taken.format(appearance), desktops).convert("RGB").crop((0, 0) + size).save(os.path.join(out, name), optimize=True)
            count += 1
            if name.startswith("1-popover"):
                uncut = split(taken.format(appearance), desktops)
                cuts = {"-split": uncut.crop((0, 0) + size)}
                if size == LANDSCAPE:
                    cuts["-split-5x4"] = uncut.crop((0, 0, FIVE_FOUR, size[1]))
                for ending, cut in cuts.items():
                    cut.save(os.path.join(out, name.replace(".png", ending + ".png")), optimize=True)
                    labelled(cut, uncut.size).save(os.path.join(out, name.replace(".png", ending + "-labelled.png")), optimize=True)
                    count += 2
            if size == PORTRAIT:
                tight = name.replace("-desktop", "-desktop-tight")
                Image.open(os.path.join(out, name)).crop((TIGHTER, 0, size[0] - TIGHTER, size[1])).save(os.path.join(out, tight), optimize=True)
                count += 1
print(f"Wrote {count} pictures to {os.path.relpath(out, os.getcwd())}")
if missing:
    print(f"Left out {', '.join(missing)}: run scripts/screenshots.sh --desktop first (with DARK_WALLPAPER for Dome's)")
