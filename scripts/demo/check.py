#!/usr/bin/env python3
# Checks pipeline.py against what macOS really does, as numbers: the share of values within N levels.
#
#   check.py colour        to_video() against CoreGraphics' own matching (ColorSync) of the same colours.
#                          Nothing on screen changes.
#   check.py dark-layer    Sidecar's dark layer against WindowServer: shows a grey ramp on the second
#                          display (or --display ID) for a second, half of it under a black window like
#                          DimmingWindow, and compares a screen capture with the model. Nothing is
#                          activated and the pointer isn't moved.
#   check.py eye-test      Whether the DCP multiplies light or encoded values by the colour matrix,
#                          seen on the screen itself, as no capture has the filter in it. Ask the user
#                          first: it turns on Grayscale (System Settings › Accessibility › Display ›
#                          Color Filters), while tiles on the main display show red, green and blue
#                          squares on greys numbered 10...95, until it's stopped (kill -TERM its PID) or
#                          --seconds pass, and then puts the filter back as it was. Ask: in each row,
#                          at which number does the square turn darker than its tile? Then
#   check.py eye-test --answer RED,GREEN,BLUE   compares those numbers with both answers. On
#                          2026-11-03 the user saw 60, 80, 40: light (58.4, 79.2, 36.6), not encoded
#                          values (30, 59, 11).
#   check.py brightness    Ask the user first: sets the main display's brightness to a few values for
#                          a moment each, reads back what the display's HID brightness was set to, and
#                          puts the brightness back.
#   check.py pointer       Whether the colour filter tints the pointer, which on Apple silicon may be a
#                          layer of its own that the display coprocessor puts over the frame, seen on
#                          the screen. Ask the user first: it turns on Color Tint, red at full
#                          intensity, until it's stopped (kill -TERM its PID) or --seconds pass, and
#                          then puts Color Filters back exactly as they were. Ask: is the pointer's
#                          white outline still white, or red like everything else? On 2026-11-03 the
#                          user saw it red: the filter tints the pointer (on the Studio Display, M4 Pro).
#   check.py switch        How macOS changes the screen over from Light to Dark and back, timed on the screen
#                          (scripts/demo/film-switch.swift) for recorder/AppearanceTransition.swift. Ask the
#                          user first: it changes the appearance to Dark and back, twice, as Safelight does,
#                          with a 40-point square in the Retina display's bottom left corner. For the
#                          wallpaper's dissolve, the desktop needs a wallpaper with a picture for Light and
#                          one for Dark, which the films say nothing about otherwise. Writes
#                          build/demo/film/switch-N.json and fits them; with --films FILE…, only fits those.
#                          On 2026-11-03, with the dark-switch scene's wallpaper on the desktop: the fade
#                          from 489–548 ms after the post, Core Animation's default curve over 0.5 s, in
#                          encoded values; the wallpaper linear over 2.0 s, from 320–400 ms (to Dark).
#
# Needs what pipeline.py needs, and screen recording permission for screencapture.
import argparse, json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path
import numpy as np
import AppKit, Foundation, Quartz
from PIL import Image, ImageDraw, ImageFont
import pipeline



def report(name, predicted, actual, levels=(0, 1, 2)):
    diff = np.abs(predicted.astype(np.int32) - actual.astype(np.int32))
    shares = ", ".join(f"{np.mean(diff <= n) * 100:.2f}% within {n}" for n in levels)
    print(f"{name}: {diff.size} values, {shares}, most off {diff.max()}")
    return diff


# --- colour ---------------------------------------------------------------------------------------

def check_colour(args):
    """to_video() against CoreGraphics drawing the same encoded colours from the display's profile into
    the video's, for every display and both video spaces."""
    rng = np.random.default_rng(1)
    rgb = np.concatenate([rng.integers(0, 256, (4096, 3)), np.repeat(np.arange(256)[:, None], 3, 1),
                          np.eye(3, dtype=int) * 255]).astype(np.float64) / 255
    rgb = rgb.reshape(1, -1, 3)
    for display_id in active_displays():
        display = pipeline.Display.live(display_id)
        for space in pipeline.VIDEO_SPACES:
            ours = pipeline.to_video(display.profile.decode(rgb), display, space)
            video_icc = bytes(Quartz.CGColorSpaceCopyICCData(Quartz.CGColorSpaceCreateWithName(pipeline.VIDEO_SPACES[space])))
            theirs = np.round(np.clip(pipeline.cg_convert(rgb, display.profile.data, video_icc), 0, 1) * 255)
            report(f"{display.name} → {space}", ours, theirs)


def active_displays():
    err, ids, count = Quartz.CGGetActiveDisplayList(8, None, None)
    return list(ids[:count])


# --- windows --------------------------------------------------------------------------------------

def app():
    application = AppKit.NSApplication.sharedApplication()
    application.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)
    return application


def screen_of(display_id):
    for screen in AppKit.NSScreen.screens():
        if screen.deviceDescription()["NSScreenNumber"] == display_id:
            return screen
    raise LookupError(f"no screen for display {display_id}")


def picture_window(values, display_id, frame):
    """A window at `frame` (points) showing `values` (0...255, pixels) as they are, in the display's colour
    space, so they reach its frame unchanged."""
    h, w = values.shape[:2]
    cs = Quartz.CGDisplayCopyColorSpace(display_id)
    data = np.ascontiguousarray(values.astype(np.uint8)).tobytes()
    provider = Quartz.CGDataProviderCreateWithData(None, data, len(data), None)
    image = Quartz.CGImageCreate(w, h, 8, 24, w * 3, cs, Quartz.kCGImageAlphaNone, provider, None, False,
                                 Quartz.kCGRenderingIntentDefault)
    window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        frame, AppKit.NSWindowStyleMaskBorderless, AppKit.NSBackingStoreBuffered, False)
    window.setColorSpace_(AppKit.NSColorSpace.alloc().initWithCGColorSpace_(cs))
    window.setHasShadow_(False)
    window.setReleasedWhenClosed_(False)
    window.setAnimationBehavior_(AppKit.NSWindowAnimationBehaviorNone)
    view = AppKit.NSView.alloc().initWithFrame_(((0, 0), frame.size))
    view.setWantsLayer_(True)
    view.layer().setContents_(image)
    view.layer().setContentsGravity_("resize")
    view.layer().setMagnificationFilter_("nearest")
    window.setContentView_(view)
    window.setLevel_(AppKit.NSStatusWindowLevel)
    window.orderFrontRegardless()
    return window


def dimming_window(frame, brightness):
    """GammaManager's DimmingWindow, letting `brightness` of what's under it through, over `frame` only."""
    window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        frame, AppKit.NSWindowStyleMaskBorderless, AppKit.NSBackingStoreBuffered, False)
    window.setBackgroundColor_(AppKit.NSColor.blackColor())
    window.setOpaque_(False)
    window.setHasShadow_(False)
    window.setIgnoresMouseEvents_(True)
    window.setReleasedWhenClosed_(False)
    window.setAnimationBehavior_(AppKit.NSWindowAnimationBehaviorNone)
    window.setLevel_(Quartz.CGShieldingWindowLevel())
    window.setAlphaValue_(float(np.float32(1) - np.float32(brightness)))  # worked out in Float, as GammaManager does
    window.orderFrontRegardless()
    return window


def run_for(seconds):
    Foundation.NSRunLoop.currentRunLoop().runUntilDate_(Foundation.NSDate.dateWithTimeIntervalSinceNow_(seconds))


def capture(display_id, frame):
    """The display's frame where `frame` (points, Cocoa coordinates) is, as screencapture saves it."""
    main_height = AppKit.NSScreen.screens()[0].frame().size.height
    x, y = frame.origin.x, main_height - frame.origin.y - frame.size.height
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "capture.png")
        subprocess.run(["screencapture", "-x", "-R", f"{x:.0f},{y:.0f},{frame.size.width:.0f},{frame.size.height:.0f}", path], check=True)
        return np.asarray(Image.open(path).convert("RGB"))


# --- dark layer -----------------------------------------------------------------------------------

def check_dark_layer(args):
    display_id = args.display or next(d for d in active_displays() if d != Quartz.CGMainDisplayID())
    screen = screen_of(display_id)
    scale = screen.backingScaleFactor()
    # Every grey and the three primaries and their mixes, 32 rows tall, twice: left in the open, right under the layer
    values = np.concatenate([np.repeat(np.arange(256)[:, None], 3, 1), np.array(
        [[r, g, b] for r in (0, 128, 255) for g in (0, 128, 255) for b in (0, 128, 255)])])
    strip = np.repeat(np.repeat(values[None], 8, 0), 2, 1).astype(np.uint8)            # 8 rows, each value 2 pixels wide
    picture = np.concatenate([strip, strip], 0)
    h, w = picture.shape[:2]
    origin = screen.frame().origin
    frame = Foundation.NSMakeRect(origin.x + 40, origin.y + 40, w / scale, h / scale)
    app()
    window = picture_window(picture, display_id, frame)
    results = []
    for brightness in args.brightness:
        layer = dimming_window(Foundation.NSMakeRect(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height / 2), brightness)
        run_for(0.5)
        shot = capture(display_id, frame)
        layer.close()
        top, bottom = shot[: h // 2], shot[h // 2:]
        predicted = np.round(pipeline.dark_layer(top / 255, brightness) * 255)
        results.append(report(f"dark layer at {brightness}", predicted, bottom))
        if args.verbose:
            row = 2 * np.arange(0, 256, 32)
            print("  in   ", top[4, row, 0]); print("  out  ", bottom[4, row, 0]); print("  model", predicted[4, row, 0].astype(int))
        report("  the picture as drawn", picture[: h // 2], top)
    window.close()


# --- eye test -------------------------------------------------------------------------------------

STEPS = np.round(np.arange(0.10, 0.951, 0.05), 2)
COLOURS = {"red": (1, 0, 0), "green": (0, 1, 0), "blue": (0, 0, 1)}


def predictions(display):
    """The grey whose tile matches each colour under Grayscale, if the matrix multiplies encoded values,
    and if it multiplies light."""
    m = pipeline.grayscale_matrix()
    out = {}
    for name, rgb in COLOURS.items():
        x = np.array([[rgb]], np.float64)
        encoded = (x @ m.T)[0, 0, 0]
        light = (display.profile.decode(x) @ m.T)[0, 0]
        out[name] = (encoded, display.profile.encode(light[None, None])[0, 0, 0])
    return out


def eye_test_picture(scale, width):
    """Three rows of tiles, red, green and blue, each tile a grey with a square of the colour in it and
    the grey's number (×100) under it, at most `width` points wide."""
    tile = min(120, int((width - 40) / len(STEPS) / 1.13))
    gap, label = max(tile // 8, 6), 36
    cols = len(STEPS)
    w = cols * tile + (cols + 1) * gap
    h = 3 * (tile + label) + 4 * gap
    image = Image.new("RGB", (w * scale, h * scale), (40, 40, 40))
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22 * scale)
    for r, rgb in enumerate(COLOURS.values()):
        y = gap + r * (tile + label + gap)
        for c, v in enumerate(STEPS):
            x = gap + c * (tile + gap)
            grey = round(v * 255)
            draw.rectangle([x * scale, y * scale, (x + tile) * scale - 1, (y + tile) * scale - 1], fill=(grey,) * 3)
            inset = tile // 4
            draw.rectangle([(x + inset) * scale, (y + inset) * scale, (x + tile - inset) * scale - 1, (y + tile - inset) * scale - 1],
                           fill=tuple(255 * np.array(rgb)))
            text = f"{round(v * 100)}"
            box = draw.textbbox((0, 0), text, font=font)
            draw.text(((x + tile / 2) * scale - (box[2] - box[0]) / 2, (y + tile + 6) * scale), text, font=font, fill=(220, 220, 220))
    return np.asarray(image), (w, h)


class ColorFilters:
    """System Settings › Accessibility › Display › Color Filters, through MediaAccessibility, as
    Safelight's ColorFilterManager drives it."""

    def __init__(self):
        import ctypes
        ma = ctypes.CDLL("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility")
        self.get_enabled, self.set_enabled = ma.MADisplayFilterPrefGetCategoryEnabled, ma.MADisplayFilterPrefSetCategoryEnabled
        self.get_type, self.set_type = ma.MADisplayFilterPrefGetType, ma.MADisplayFilterPrefSetType
        self.get_hue, self.set_hue = ma.MADisplayFilterPrefGetSingleColorHue, ma.MADisplayFilterPrefSetSingleColorHue
        self.get_intensity, self.set_intensity = ma.MADisplayFilterPrefGetSingleColorIntensity, ma.MADisplayFilterPrefSetSingleColorIntensity
        self.get_enabled.restype, self.get_enabled.argtypes = ctypes.c_bool, [ctypes.c_long]
        self.set_enabled.argtypes = [ctypes.c_long, ctypes.c_bool]
        self.get_type.restype, self.get_type.argtypes = ctypes.c_long, [ctypes.c_long]
        self.set_type.argtypes = [ctypes.c_long, ctypes.c_long]
        self.get_hue.restype = self.get_intensity.restype = ctypes.c_double
        self.set_hue.argtypes = self.set_intensity.argtypes = [ctypes.c_double]

    COLOR, GRAYSCALE, COLOR_TINT = 1, 1, 16  # category 1 is Color; within it, type 1 Grayscale and 16 Color Tint (MADisplayFilterCopySystemFilter's bits 0 and 4)

    def state(self):
        """The switch, the filter, and Color Tint's hue and intensity"""
        return self.get_enabled(self.COLOR), self.get_type(self.COLOR), self.get_hue(), self.get_intensity()

    def restore(self, state):
        # In the order that never shows another filter, hue or intensity for a moment
        enabled, kind, hue, intensity = state
        if enabled:
            self.set_hue(hue)
            self.set_intensity(intensity)
            self.set_type(self.COLOR, kind)
            self.set_enabled(self.COLOR, True)
        else:
            self.set_enabled(self.COLOR, False)
            self.set_type(self.COLOR, kind)
            self.set_hue(hue)
            self.set_intensity(intensity)


def check_eye_test(args):
    display_id = args.display or Quartz.CGMainDisplayID()
    display = pipeline.Display.live(display_id)
    expected = predictions(display)
    if args.answer:
        # Each answer is the first tile whose square is darker, so the square matches a grey between
        # the tile before it and that one
        answers = [round(float(a)) for a in args.answer.split(",")]
        print(f"{display.name}, the first tile (×100) whose square is darker than it:")
        fits = {"encoded values": 0, "light": 0}
        for (name, predicted), answer in zip(expected.items(), answers):
            first = [next((round(v * 100) for v in STEPS if v > p - 1e-9), None) for p in predicted]
            for kind, tile in zip(fits, first):
                fits[kind] += tile == answer
            print(f"  {name:5}  seen {answer:3d}   if encoded values {first[0]} (matches {predicted[0] * 100:.1f})"
                  f"   if light {first[1]} (matches {predicted[1] * 100:.1f})")
        print("rows that fit: " + ", ".join(f"{n} of {len(answers)} if {kind}" for kind, n in fits.items()))
        return
    screen = screen_of(display_id)
    scale = int(screen.backingScaleFactor())
    sf = screen.frame()
    picture, (w, h) = eye_test_picture(scale, sf.size.width)
    frame = Foundation.NSMakeRect(sf.origin.x + (sf.size.width - w) // 2, sf.origin.y + (sf.size.height - h) // 2, w, h)
    app()
    window = picture_window(picture, display_id, frame)
    run_for(0.3)
    drawn = capture(display_id, frame)
    report("the tiles as drawn (from a capture)", picture[: drawn.shape[0], : drawn.shape[1]], drawn)
    if args.dry_run:
        window.close()
        return
    filters = ColorFilters()
    before = filters.state()
    # Stopping it (Control-C, or kill with its PID) ends the wait, and the filter's put back
    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.append(True))
    try:
        filters.set_type(filters.COLOR, filters.GRAYSCALE)
        filters.set_enabled(filters.COLOR, True)
        print(f"Grayscale is on for up to {args.seconds:.0f} s, until stopped (PID {os.getpid()}). In each row the square "
              "is lighter than its tile on the left and darker on the right: at which number does it turn darker?", flush=True)
        deadline = time.time() + args.seconds
        while not stop and time.time() < deadline:
            run_for(0.2)
    finally:
        filters.restore(before)
        window.close()
    print("Color Filters are back as they were:", "on" if before[0] else "off", f"(type {before[1]})")
    print("Then: check.py eye-test --answer RED,GREEN,BLUE")


# --- pointer --------------------------------------------------------------------------------------

def check_pointer(args):
    filters = ColorFilters()
    before = filters.state()
    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.append(True))
    try:
        # Red at full intensity takes every white on the screen to red, so a white outline left alone
        # stands out
        filters.set_hue(0)
        filters.set_intensity(1)
        filters.set_type(filters.COLOR, filters.COLOR_TINT)
        filters.set_enabled(filters.COLOR, True)
        print(f"Color Tint is on, red at full intensity, for up to {args.seconds:.0f} s, until stopped (PID {os.getpid()}). "
              "Is the pointer's white outline still white, or red like everything else?", flush=True)
        deadline = time.time() + args.seconds
        while not stop and time.time() < deadline:
            time.sleep(0.2)
    finally:
        filters.restore(before)
    after = filters.state()
    print("Color Filters are back as they were:" if after == before else "Color Filters AREN'T back as they were:",
          "on" if after[0] else "off", f"(type {after[1]}, hue {after[2]}, intensity {after[3]})")


# --- switch ---------------------------------------------------------------------------------------

def bezier(x1, y1, x2, y2, x):
    """The cubic Bézier from (0, 0) to (1, 1) with these control points, at times x, by bisection"""
    x = np.clip(x, 0, 1)
    low, high = np.zeros_like(x), np.ones_like(x)
    point = lambda a, b, s: 3 * a * s * (1 - s) ** 2 + 3 * b * s * s * (1 - s) + s ** 3
    for _ in range(50):
        middle = (low + high) / 2
        below = point(x1, x2, middle) < x
        low, high = np.where(below, middle, low), np.where(below, high, middle)
    return point(y1, y2, (low + high) / 2)


def check_switch(args):
    root = Path(__file__).resolve().parents[2]
    folder = root / "build" / "demo" / "film"
    films = [Path(f) for f in args.films or []]
    if not films:
        folder.mkdir(parents=True, exist_ok=True)
        tool = folder / "film-switch"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-o", str(tool), str(root / "scripts" / "demo" / "film-switch.swift")], check=True)
        for run in range(1, args.runs + 1):
            films.append(folder / f"switch-{run}.json")
            subprocess.run([str(tool), str(films[-1]), "--pause", str(args.pause)], check=True)
            time.sleep(2)
    # Core Animation's default curve, which AquaAppearanceHelper's fade has, and the sRGB tone curve, for
    # a blend in light rather than encoded values
    default = lambda x: bezier(0.25, 0.1, 0.25, 1, x)
    decode = lambda v: np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
    for path in films:
        film = json.loads(path.read_text())
        for change in ("toDark", "toLight"):
            times = {key: float(value) for key, value in film[change].items()}
            posted = times["posted"]
            print(f"{path.name} {change}: the begin call took {(times['begun'] - times['begin']) * 1000:.0f} ms, "
                  f"called back {(times['calledBack'] - posted) * 1000:.0f} ms after the post")
            # Each picture taken somewhere between asking and getting it: the middle
            samples = [s for s in film["samples"] if -0.2 < s["time"] - posted < 3.0]
            seen = [(0.5 * (s["time"] + s["after"]) - posted, s["square"][0]) for s in samples if s.get("square")]
            t, v = np.array([x[0] for x in seen]), np.array([x[1] for x in seen])
            for domain, values in (("encoded values", v), ("light", decode(v))):
                shown = (values - values[-1]) / (values[0] - values[-1])
                start, rms = min(((st, np.sqrt(np.mean((1 - default((t - st) / 0.5) - shown) ** 2))) for st in np.arange(0.2, 1.2, 0.001)), key=lambda x: x[1])
                print(f"  the picture, blended in {domain}: Core Animation's default curve over 0.5 s from {start * 1000:.0f} ms (rms {rms:.3f})")
            strip = [(0.5 * (s["time"] + s["after"]) - posted, s["desktop"][:3]) for s in samples if s.get("desktop")]
            t, d = np.array([x[0] for x in strip]), np.array([x[1] for x in strip])
            if np.abs(d[-1] - d[0]).max() < 0.02:
                print("  the wallpaper didn't change: it has no picture for each appearance")
                continue
            done = (d - d[0]) / (d[-1] - d[0])
            middle = (done.mean(1) > 0.1) & (done.mean(1) < 0.9)
            slope, offset = np.polyfit(t[middle], done[middle].mean(1), 1)
            print(f"  the wallpaper: linear over {1 / slope:.2f} s from {-offset / slope * 1000:.0f} ms, its channels within "
                  f"{np.ptp(done[middle], axis=1).max():.3f} of each other (so in encoded values), "
                  f"rms {np.sqrt(np.mean((done[middle].mean(1) - slope * t[middle] - offset) ** 2)):.3f}")


# --- brightness -----------------------------------------------------------------------------------

def check_brightness(args):
    import ctypes
    ds = ctypes.CDLL("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
    ds.DisplayServicesGetBrightness.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
    ds.DisplayServicesSetBrightness.argtypes = [ctypes.c_uint32, ctypes.c_float]
    display_id = Quartz.CGMainDisplayID()
    display = pipeline.Display.live(display_id)
    low, high, _ = pipeline.hid_brightness(display.name)
    before = ctypes.c_float()
    ds.DisplayServicesGetBrightness(display_id, ctypes.byref(before))
    try:
        for value in args.values:
            ds.DisplayServicesSetBrightness(display_id, value)
            time.sleep(0.6)
            hid = pipeline.hid_brightness(display.name)[2]
            print(f"slider {value:.3f}: HID {hid} (model {max(round(value * high), low)}), white {hid / 100:.0f} nits")
    finally:
        ds.DisplayServicesSetBrightness(display_id, before.value)
    print(f"brightness back at {before.value:.3f}")


def main():
    parser = argparse.ArgumentParser(description="Checks pipeline.py against macOS.")
    sub = parser.add_subparsers(dest="check", required=True)
    sub.add_parser("colour")
    p = sub.add_parser("dark-layer")
    p.add_argument("--display", type=int)
    p.add_argument("--brightness", type=float, nargs="*", default=[0.1, 0.17, 0.25, 0.33, 0.5, 0.6, 0.75, 0.8, 0.85, 0.9, 0.95, 0.99])
    p.add_argument("--verbose", action="store_true")
    p = sub.add_parser("eye-test")
    p.add_argument("--seconds", type=float, default=25)
    p.add_argument("--answer", help="the numbers of the tiles whose squares disappear: red,green,blue")
    p.add_argument("--display", type=int, help="where the tiles go (the main display if left out)")
    p.add_argument("--dry-run", action="store_true", help="show the tiles for a moment and check they're drawn as they are, leaving the filter alone")
    p = sub.add_parser("brightness")
    p.add_argument("--values", type=float, nargs="*", default=[0.75, 0.5, 0.25])
    p = sub.add_parser("pointer")
    p.add_argument("--seconds", type=float, default=300)
    p = sub.add_parser("switch")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--pause", type=float, default=4.5, help="seconds in Dark, then in Light")
    p.add_argument("--films", nargs="*", help="fit these films rather than taking new ones")
    args = parser.parse_args()
    {"colour": check_colour, "dark-layer": check_dark_layer, "eye-test": check_eye_test, "brightness": check_brightness,
     "pointer": check_pointer, "switch": check_switch}[args.check](args)


if __name__ == "__main__":
    main()
