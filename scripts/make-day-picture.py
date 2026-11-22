#!/usr/bin/env python3
# Writes docs/day.jpg, the README's first picture: the whole desktop at four times of day on Safelight's
# default schedule, in four parts between slanted lines, each as the screen shows it then, with its time
# of day written at its foot. No screenshot has the color filter in it, as macOS applies it after the
# frame is drawn, so the filter is the demo videos' (scripts/demo/pipeline.py): macOS's own matrix,
# multiplying light. The settings are the ones Safelight's own code gives ColorKeyframe.defaultSchedule
# at those times (scripts/demo/compose.py works them out as the app does).
#
#   scripts/make-day-picture.py [--dimmed] [--times 12:00,17:30,19:00,21:00]
#                               [--light <file>] [--dark <file>] [--out <file>]
#
# The desktop is the demo recorder's, drawn off screen with the popover closed: Sonoma Horizon in Light
# and Dome in Dark, the menu bar's items at 21:00 in the last part, which is why the last time is 21:00
# and has to be in Dark. `scripts/make-demo.sh --record night-desktop` draws it (and needs
# build/wallpapers/Dome.heic; scripts/screenshots.sh says where Apple keeps it).
#
# The schedule's brightness isn't in the picture: a display's backlight changes how much light the whole
# screen gives off, which a picture on someone else's screen can't have, and drawn as darker pixels the
# last part is nearly black on a web page. --dimmed draws it anyway, each part as bright as a Studio
# Display's backlight is at the schedule's brightness then, beside its brightest.
#
# The picture is in Display P3, like the README's screenshots, so the red is the one a Mac's display
# shows. scripts/make-reddit-pictures.py makes three-part pictures of the same kind, in sRGB, for Reddit.
#
# Needs Pillow, NumPy and PyObjC.
import argparse, os, re, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(root, "scripts", "demo"))
import compose, pipeline

NIGHT = os.path.join(root, "build", "demo", "recorder", "recorded", "night-desktop")
TIMES = "12:00,17:30,19:00,21:00"
# How far each line leans: its top this many pixels right of its middle, its bottom as many left
LEAN = 160
# The times of day: in the menu bar's font, their middle this far above the bottom, with a soft shadow
# so they are as clear over Light's bright desktop as over Dark's
FONT, SIZE, UP, SHADOW = "/System/Library/Fonts/SFNS.ttf", 66, 102, 150
# The color filter's lowest intensity (ColorFilterManager.intensityRange's): below it the filter is off
LOWEST_INTENSITY = 0.25
# The brightness below which Safelight has the backlight at its lowest and dims the picture instead
# (CombinedBrightness.lowestBacklight), and how much light a Studio Display's backlight gives at its
# lowest, as a share of its most: 4 of 600 nits (scripts/demo/pipeline.py, hid_brightness)
LOWEST_BACKLIGHT, LOWEST_LIGHT = 0.25, 400 / 60000


def default_schedule():
    """Safelight's default schedule, read from its source, as the demo's scenes write a schedule"""
    source = open(os.path.join(root, "Safelight", "Safelight.swift")).read()
    rows = re.search(r"static let defaultSchedule: \[ColorKeyframe\] = \[\n(.*?)\n    \]", source, re.S)
    row = (r"ColorKeyframe\(minute: (\d+) \* 60(?: \+ (\d+))?, +isColorFilterOn: (true|false), +intensity: ([\d.]+), +tint: ([\d.]+), +"
           r"brightness: ([\d.]+), +isDarkAppearance: (true|false)\),?")
    found = [re.fullmatch(row, line.strip()) for line in rows.group(1).split("\n")] if rows else [None]
    if not all(found):
        sys.exit("Couldn't read ColorKeyframe.defaultSchedule from Safelight.swift")
    return [{"time": f"{int(hour):02}:{int(minute or 0):02}", "colorFilter": on == "true", "intensity": float(intensity), "tint": float(tint),
             "brightness": float(brightness), "appearance": "dark" if dark == "true" else "light"}
            for hour, minute, on, intensity, tint, brightness, dark in (match.groups() for match in found)]


def looks(schedule, times, dimmed):
    """What the schedule has the screen at, at each time: (Dark?, the filter's (hue, intensity) or None
    where it's off, the backlight)"""
    found = []
    for time in times:
        intensity, tint, brightness, dark = compose.schedule_settings(schedule, int(time[:2]) * 60 + int(time[3:]))
        if dimmed and brightness < LOWEST_BACKLIGHT:
            sys.exit(f"The schedule's brightness at {time} is below {LOWEST_BACKLIGHT}, where Safelight dims the picture as well, which isn't drawn here")
        # As ColorKeyframe.Settings has it: the filter is off below its lowest intensity. And the backlight
        # as CombinedBrightness.backlight(at:) has it: the brightness's top three quarters
        found.append((bool(dark), (float(tint) / 360, min(float(intensity), 1)) if intensity >= LOWEST_INTENSITY else None,
                      (float(brightness) - LOWEST_BACKLIGHT) / (1 - LOWEST_BACKLIGHT) if dimmed else 1.0))
        print(f"{time}: {'Dark' if dark else 'Light'}, " + (f"filter {float(tint):.0f}° at {float(intensity):.2f}" if found[-1][1] else "filter off")
              + f", brightness {float(brightness):.2f}" + (f" (backlight {found[-1][2]:.2f})" if dimmed else " (not drawn)"))
    if not found[-1][0]:
        sys.exit(f"The schedule isn't Dark at {times[-1]}, as the desktop with the menu bar's items is recorded")
    return found


def draw_wallpaper(path, width, height):
    """A wallpaper file filling `width` by `height` pixels in Display P3, as Desktop.swift draws it."""
    raw = os.fsencode(os.path.abspath(path))
    url = pipeline.Quartz.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), False)
    source = pipeline.Quartz.CGImageSourceCreateWithURL(url, None)
    picture = pipeline.Quartz.CGImageSourceCreateImageAtIndex(source, 0, None) if source else None
    if picture is None:
        sys.exit(f"Couldn't read the wallpaper {path}")
    space = pipeline.Quartz.CGColorSpaceCreateWithName(pipeline.VIDEO_SPACES["display-p3"])
    ctx = pipeline.Quartz.CGBitmapContextCreate(None, width, height, 8, width * 4, space, pipeline.Quartz.kCGImageAlphaNoneSkipLast)
    fill = max(width / pipeline.Quartz.CGImageGetWidth(picture), height / pipeline.Quartz.CGImageGetHeight(picture))
    sw, sh = pipeline.Quartz.CGImageGetWidth(picture) * fill, pipeline.Quartz.CGImageGetHeight(picture) * fill
    pipeline.Quartz.CGContextSetInterpolationQuality(ctx, pipeline.Quartz.kCGInterpolationHigh)
    pipeline.Quartz.CGContextDrawImage(ctx, (((width - sw) / 2, (height - sh) / 2), (sw, sh)), picture)
    data = pipeline.Quartz.CGBitmapContextGetData(ctx).as_buffer(width * height * 4)
    image = Image.fromarray(np.frombuffer(data, dtype=np.uint8).reshape(height, width, 4)[..., :3].copy(), "RGB")
    image.info["icc_profile"] = bytes(pipeline.Quartz.CGColorSpaceCopyICCData(space))
    return image


def closed_menubar():
    """The closed menu bar's items in Dark over nothing, recovered from night-desktop's menubar-dark.png
    (without Safelight's open-popover capsule) and desktop-closed.png."""
    mb = np.asarray(Image.open(os.path.join(NIGHT, "menubar-dark.png")), np.float64)
    dc = np.asarray(Image.open(os.path.join(NIGHT, "desktop-closed.png")).convert("RGB"), np.float64)
    wd = np.asarray(Image.open(os.path.join(NIGHT, "wallpaper-dark.png")).convert("RGB"), np.float64)
    cap = np.nonzero(mb[6:15, :, 3] > 0)[1]
    x0, x1 = max(0, int(cap.min()) - 10), min(mb.shape[1], int(cap.max()) + 11)
    patch_dc, patch_wd = dc[:, x0:x1], wd[:, x0:x1]
    a = np.clip((patch_dc - patch_wd) / np.maximum(255.0 - patch_wd, 1.0), 0.0, 1.0).mean(axis=2)
    a[(patch_dc == patch_wd).all(axis=2)] = 0.0
    closed = mb.copy()
    closed[:, x0:x1, :3] = 255.0
    closed[:, x0:x1, 3] = np.round(a * 255.0)
    return closed


def desktops(looks, light_path=None, dark_path=None):
    """The whole desktop with each look, as the screen shows it, in Display P3 at half its size, a point
    to the pixel: the last, the desktop the recorder drew, and the ones before it their appearance's
    wallpaper alone, as the menu bar's items are all at its right, in the last part. And where the
    leftmost of those items begins."""
    ref = Image.open(os.path.join(NIGHT, "wallpaper-dark.png"))
    width, height = ref.size
    light_img = draw_wallpaper(light_path, width, height) if light_path else Image.open(os.path.join(NIGHT, "wallpaper-light.png"))
    if dark_path:
        dark_img = draw_wallpaper(dark_path, width, height)
        mb = closed_menubar()
        alpha = mb[..., 3:4] / 255.0
        comp = np.round(mb[..., :3] * alpha + np.asarray(dark_img, np.float64) * (1.0 - alpha)).astype(np.uint8)
        closed_img = Image.fromarray(comp, "RGB")
        closed_img.info["icc_profile"] = dark_img.info["icc_profile"]
    else:
        dark_img = ref
        closed_img = Image.open(os.path.join(NIGHT, "desktop-closed.png"))
    drawn = []
    for part, (dark, tint, backlight) in enumerate(looks):
        image = closed_img if part == len(looks) - 1 else dark_img if dark else light_img
        display = pipeline.Display("desktop", pipeline.BACKLIGHT, pipeline.Profile(image.info["icc_profile"]), LOWEST_LIGHT)
        frame = np.asarray(image.convert("RGB"), np.float64) / 255
        shown = Image.fromarray(pipeline.to_video(pipeline.shown(frame, display, tint=tint, brightness=backlight), display, "display-p3"))
        drawn.append(shown.resize((image.width // 2, image.height // 2), Image.BOX))
    # The menu bar's items are where the Dark desktop isn't its wallpaper alone
    alone = np.asarray(Image.open(os.path.join(NIGHT, "wallpaper-dark.png")).convert("RGB"))
    items = np.flatnonzero((np.asarray(Image.open(os.path.join(NIGHT, "desktop-closed.png")).convert("RGB")) != alone).any(axis=(0, 2)))
    if not len(items):
        sys.exit("The recorded desktop has nothing in its menu bar")
    return drawn, int(items[0]) // 2


def through_day(drawn, items, times):
    """The desktops side by side, each in its own share of the width between slanted lines, with its time
    of day at its foot. `items` is where the menu bar's begin, which only the last desktop has."""
    width, height = drawn[0].size
    line = lambda part, y: width * part / len(drawn) + LEAN - 2 * LEAN * y / height
    if line(len(drawn) - 1, 0) > items:
        sys.exit("The menu bar's items reach into a part of the desktop that's drawn without them")
    picture = np.asarray(drawn[-1], np.float64)
    for part in range(len(drawn) - 1, 0, -1):  # each over the ones to its right
        mask = Image.new("L", (width * 4, height * 4), 0)  # drawn four times the size for a smooth edge
        ImageDraw.Draw(mask).polygon([(0, 0), (line(part, 0) * 4, 0), (line(part, height) * 4, height * 4), (0, height * 4)], fill=255)
        mask = np.asarray(mask.resize((width, height), Image.LANCZOS), np.float64)[..., None] / 255
        picture = np.asarray(drawn[part - 1], np.float64) * mask + picture * (1 - mask)
    picture = Image.fromarray(np.round(picture).astype(np.uint8))
    font = ImageFont.truetype(FONT, SIZE)
    font.set_variation_by_name("Semibold")
    y = height - UP
    edges = [0] + [line(part, y) for part in range(1, len(drawn))] + [width]
    shadow, words = Image.new("L", picture.size, 0), Image.new("L", picture.size, 0)
    for part, time in enumerate(times):
        place = ((edges[part] + edges[part + 1]) / 2, y)
        ImageDraw.Draw(shadow).text(place, time, font=font, anchor="mm", fill=SHADOW)
        ImageDraw.Draw(words).text(place, time, font=font, anchor="mm", fill=255)
    picture = Image.composite(Image.new("RGB", picture.size, (0, 0, 0)), picture, shadow.filter(ImageFilter.GaussianBlur(6)))
    return Image.composite(Image.new("RGB", picture.size, (255, 255, 255)), picture, words)


def main():
    parser = argparse.ArgumentParser(description="Writes the README's picture of the desktop through a day.")
    parser.add_argument("--times", default=TIMES, help="the times of day, HH:MM with commas between; the last is the recorded desktop's")
    parser.add_argument("--dimmed", action="store_true", help="draw the schedule's brightness too, as a Studio Display's backlight")
    parser.add_argument("--light", help="wallpaper file to use for Light instead of night-desktop's")
    parser.add_argument("--dark", help="wallpaper file to use for Dark instead of night-desktop's")
    parser.add_argument("--out", default=os.path.join(root, "docs", "day.jpg"))
    args = parser.parse_args()
    times = args.times.split(",")
    needed = ("desktop-closed.png", "wallpaper-light.png", "wallpaper-dark.png") + (("menubar-dark.png",) if args.dark else ())
    if not all(os.path.exists(os.path.join(NIGHT, name)) for name in needed):
        sys.exit("Run scripts/make-demo.sh --record night-desktop first: it draws the desktop")
    drawn, items = desktops(looks(default_schedule(), times, args.dimmed), args.light, args.dark)
    picture = through_day(drawn, items, times)
    icc = bytes(pipeline.Quartz.CGColorSpaceCopyICCData(pipeline.Quartz.CGColorSpaceCreateWithName(pipeline.VIDEO_SPACES["display-p3"])))
    if args.out.endswith(".png"):
        picture.save(args.out, icc_profile=icc, optimize=True)
    else:
        # 4:4:4, as the red parts are all colour, which 4:2:0 halves
        picture.save(args.out, quality=88, subsampling=0, optimize=True, icc_profile=icc)
    print(f"{os.path.relpath(args.out, os.getcwd())}: {picture.width} × {picture.height}, {os.path.getsize(args.out) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
