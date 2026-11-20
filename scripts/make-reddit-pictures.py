#!/usr/bin/env python3
# Writes the pictures for the r/coolgithubprojects gallery to build/reddit/coolgithubprojects/, from the
# README's screenshots in docs/ (scripts/screenshots.sh draws those). The README's copies are see-through
# around the window, and Reddit would fill that with a colour of its own, so each is put on a ground of
# its appearance: black for Dark, a light grey for Light.
#
#   scripts/make-reddit-pictures.py
#
#   1-popover.png, 1-popover-light.png          the popover, 2256 × 1355 like the Schedule's
#   3-schedule.png, 3-schedule-light.png        the Schedule window
#   1-popover-portrait(-light).png              the popover on a 4:5 ground, 1080 × 1350
#   1-popover-portrait-no-clock(-light).png     the same without the menu bar's clock, so the popover
#                                               itself is in the middle rather than it and the clock
#   1-popover-centred(-light).png and           with the clock, but the popover itself in the middle, so
#   1-popover-portrait-centred(-light).png      the clock reaches further to the right than the icon is
#                                               from the left
#   1-popover-desktop(-light).png,              over a desktop, as on screen: the wallpapers the demo has,
#   1-popover-portrait-desktop(-light).png and  Sonoma Horizon in Light and Sonoma's Dark picture in Dark,
#   3-schedule-desktop(-light).png              with the popover's glass drawn over them. These are from
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
#   …-labelled-quiet.png                        the same with the words as captions rather than a headline:
#                                               13 points, regular and greyed like the popover's own
#                                               "Light" and "Dark", so the eye goes to the popover first
#   2-day-desktop-dome.png                      the whole desktop through a day on the default schedule,
#                                               2560 × 1440, in three parts between slanted lines: at
#                                               12:00 (Light, Sonoma Horizon, no filter), at 18:15 (the
#                                               same with the filter half way in: red at 0.4) and at 21:00
#                                               (Dark, Dome, red at 0.9), each as the screen shows it then.
#                                               The settings are the ones Safelight's own code gives
#                                               ColorKeyframe.defaultSchedule at those times. The desktop
#                                               is the demo recorder's, drawn off screen with the popover
#                                               closed: `scripts/make-demo.sh --record night-desktop`
#                                               (which needs build/wallpapers/Dome.heic), and the picture is
#                                               left out without it. The brightness isn't applied here either.
#   2-day-desktop-dome-5x4.png                  the same of the right of the desktop, 1750 × 1440, the shape
#                                               of the popover's -5x4 pictures, in three parts of its own
#   2-day-desktop-dome(-5x4)-labelled.png       the two with each part's time of day written at its foot,
#                                               as large for the picture's width as the -5x4 pictures'
#                                               words are
#
# Needs Pillow (pip install pillow), and for the -split and -day pictures NumPy and PyObjC as well.
import io, os, re, sys
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
# The -labelled-quiet pictures' words: (size, weight, how much of white they are, how dark their shadow)
LOUD, QUIET = (LABEL_SIZE, "Semibold", 1.0, 150), (26, "Regular", 0.6, 90)
# The desktop through a day: the times of day its parts are at, the recording its desktop is from, and
# the color filter's lowest intensity (ColorFilterManager.intensityRange's, which macOS has had at 0.25)
DAY = ("12:00", "18:15", "21:00")
NIGHT = os.path.join(root, "build", "demo", "recorder", "recorded", "night-desktop")
LOWEST_INTENSITY = 0.25

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

def written(picture, labels, places, style=LOUD):
    """`picture` with each of `labels` written at its place: (where, which point of the words is there)"""
    size, weight, white, dark = style
    font = ImageFont.truetype(LABEL_FONT, size)
    font.set_variation_by_name(weight)
    # A soft shadow under the words, so they are as clear over Light's bright desktop as over Dark's
    shadow = Image.new("L", picture.size, 0)
    for label, (place, anchor) in zip(labels, places):
        ImageDraw.Draw(shadow).text(place, label, font=font, anchor=anchor, fill=dark)
    picture = Image.composite(Image.new("RGB", picture.size, (0, 0, 0)), picture, shadow.filter(ImageFilter.GaussianBlur(6)))
    words = Image.new("L", picture.size, 0)
    for label, (place, anchor) in zip(labels, places):
        ImageDraw.Draw(words).text(place, label, font=font, anchor=anchor, fill=round(255 * white))
    return Image.composite(Image.new("RGB", picture.size, (255, 255, 255)), picture, words)

def labelled(picture, whole, style=LOUD):
    """A -split picture, or a cut of one that has its left edge, with the halves' names written on either
    side of the line. `whole` is the size of the picture the line was drawn through."""
    y = picture.height - LABEL_UP
    line = whole[0] / 2 + LEAN - 2 * LEAN * y / whole[1]
    return written(picture, LABELS, (((line - LABEL_GAP, y), "rm"), ((line + LABEL_GAP, y), "lm")), style)

def default_schedule():
    """Safelight's default schedule, read from its source, as the demo's scenes write a schedule"""
    source = open(os.path.join(root, "Safelight", "Safelight.swift")).read()
    rows = re.search(r"static let defaultSchedule: \[ColorKeyframe\] = \[\n(.*?)\n    \]", source, re.S)
    row = (r"ColorKeyframe\(minute: (\d+) \* 60(?: \+ (\d+))?, +isColorFilterOn: (true|false), +intensity: ([\d.]+), +tint: ([\d.]+), +"
           r"brightness: ([\d.]+), +isDarkAppearance: (true|false)\),?")
    found = [re.fullmatch(row, line.strip()) for line in rows.group(1).split("\n")] if rows else [None]
    if not all(found):
        sys.exit("Couldn't read ColorKeyframe.defaultSchedule from Safelight.swift for the desktop through a day")
    return [{"time": f"{int(hour):02}:{int(minute or 0):02}", "colorFilter": on == "true", "intensity": float(intensity), "tint": float(tint),
             "brightness": float(brightness), "appearance": "dark" if dark == "true" else "light"}
            for hour, minute, on, intensity, tint, brightness, dark in (match.groups() for match in found)]

def day():
    """The whole desktop at each of DAY's times on the default schedule, as the screen shows it then, in
    sRGB at half its size, a point to the pixel: in Light the wallpaper alone, as the menu bar's items are
    all at its right, in the last part, and in Dark the desktop the recorder drew. And where the
    leftmost of those items begins, which through_day() keeps in the last part."""
    import numpy as np
    sys.path.insert(0, os.path.join(root, "scripts", "demo"))
    import compose, pipeline
    schedule, looks = default_schedule(), []
    for time in DAY:
        intensity, tint, _, dark = compose.schedule_settings(schedule, int(time[:2]) * 60 + int(time[3:]))
        # As ColorKeyframe.Settings has it: the filter is off below its lowest intensity
        looks.append((bool(dark), (float(tint) / 360, min(float(intensity), 1)) if intensity >= LOWEST_INTENSITY else None))
    if [dark for dark, _ in looks] != [False, False, True]:
        sys.exit(f"The default schedule isn't Light, Light and Dark at {', '.join(DAY)} any more, as the desktop through a day is drawn")
    desktops = []
    for dark, tint in looks:
        image = Image.open(os.path.join(NIGHT, "desktop-closed.png" if dark else "wallpaper-light.png"))
        display = pipeline.Display("desktop", pipeline.BACKLIGHT, pipeline.Profile(image.info["icc_profile"]))
        frame = np.asarray(image.convert("RGB"), np.float64) / 255
        shown = Image.fromarray(pipeline.to_video(pipeline.shown(frame, display, tint=tint), display, "srgb"))
        desktops.append(shown.resize((image.width // 2, image.height // 2), Image.BOX))
    # The menu bar's items are where the Dark desktop isn't its wallpaper alone
    alone = np.asarray(Image.open(os.path.join(NIGHT, "wallpaper-dark.png")).convert("RGB"))
    items = np.flatnonzero((np.asarray(Image.open(os.path.join(NIGHT, "desktop-closed.png")).convert("RGB")) != alone).any(axis=(0, 2)))
    if not len(items):
        sys.exit("The recorded desktop has nothing in its menu bar")
    return desktops, int(items[0]) // 2

def through_day(desktops, items, left=0):
    """The desktops of day() from `left` to their right edge, each in its own third of that between lines
    that slant as the -split pictures' does, with each part's time written at its foot or not: the words
    as large for the picture's width as the -5x4 pictures' are for theirs. `items` is where the menu
    bar's begin, which only the last desktop has."""
    import numpy as np
    width, height = desktops[0].width - left, desktops[0].height
    lean = LEAN * height / LANDSCAPE[1]
    line = lambda part, y: width * part / len(desktops) + lean - 2 * lean * y / height
    if left + line(len(desktops) - 1, 0) > items:
        sys.exit("The menu bar's items reach into a part of the desktop through a day that's drawn without them")
    picture = np.asarray(desktops[-1].crop((left, 0, left + width, height)), np.float64)
    for part in range(len(desktops) - 1, 0, -1):  # each over the ones to its right
        mask = Image.new("L", (width * 4, height * 4), 0)  # drawn four times the size for a smooth edge
        ImageDraw.Draw(mask).polygon([(0, 0), (line(part, 0) * 4, 0), (line(part, height) * 4, height * 4), (0, height * 4)], fill=255)
        mask = np.asarray(mask.resize((width, height), Image.LANCZOS), np.float64)[..., None] / 255
        picture = np.asarray(desktops[part - 1].crop((left, 0, left + width, height)), np.float64) * mask + picture * (1 - mask)
    picture = Image.fromarray(np.round(picture).astype(np.uint8))
    larger = width / FIVE_FOUR
    y = height - LABEL_UP * larger
    edges = [0] + [line(part, y) for part in range(1, len(desktops))] + [width]
    places = [(((edges[part] + edges[part + 1]) / 2, y), "mm") for part in range(len(desktops))]
    return picture, written(picture, DAY, places, (round(LOUD[0] * larger),) + LOUD[1:])

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
                ("schedule-{}-desktop-1128x678.png", "3-schedule-desktop{}.png", LANDSCAPE)]

os.makedirs(out, exist_ok=True)
count, missing = 0, []
for appearance, suffix in (("dark", ""), ("light", "-light")):
    popover, schedule = srgb(f"popover-{appearance}.png"), srgb(f"schedule-{appearance}.png")
    write(f"1-popover{suffix}.png", popover, LANDSCAPE, appearance)
    write(f"3-schedule{suffix}.png", schedule, LANDSCAPE, appearance)
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
                    labelled(cut, uncut.size, QUIET).save(os.path.join(out, name.replace(".png", ending + "-labelled-quiet.png")), optimize=True)
                    count += 3
            if size == PORTRAIT:
                tight = name.replace("-desktop", "-desktop-tight")
                Image.open(os.path.join(out, name)).crop((TIGHTER, 0, size[0] - TIGHTER, size[1])).save(os.path.join(out, tight), optimize=True)
                count += 1
if all(os.path.exists(os.path.join(NIGHT, name)) for name in ("desktop-closed.png", "wallpaper-light.png")):
    desktops, items = day()
    # The right of the desktop in the shape of the -5x4 pictures
    cuts = {"": 0, "-5x4": desktops[0].width - round(desktops[0].height * FIVE_FOUR / LANDSCAPE[1])}
    for ending, left in cuts.items():
        for name, picture in zip(("", "-labelled"), through_day(desktops, items, left)):
            picture.save(os.path.join(out, f"2-day-desktop-dome{ending}{name}.png"), optimize=True)
        count += 2
else:
    missing.append("2-day-desktop-dome.png (scripts/make-demo.sh --record night-desktop draws its desktop)")
print(f"Wrote {count} pictures to {os.path.relpath(out, os.getcwd())}")
if missing:
    print(f"Left out {', '.join(missing)}: run scripts/screenshots.sh --desktop first (with DARK_WALLPAPER for Dome's)")
