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
#                          Color Filters) for --seconds, while tiles on the main display show red, green
#                          and blue squares on greys; the user says which tile's square disappears,
#                          and the filter is put back as it was. Then
#   check.py eye-test --answer RED,GREEN,BLUE   compares those tiles' numbers with both answers.
#   check.py brightness    Ask the user first: sets the main display's brightness to a few values for
#                          a moment each, reads back what the display's HID brightness was set to, and
#                          puts the brightness back.
#
# Needs what pipeline.py needs, and screen recording permission for screencapture.
import argparse, os, subprocess, sys, tempfile, time
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
        self.get_enabled.restype, self.get_enabled.argtypes = ctypes.c_bool, [ctypes.c_long]
        self.set_enabled.argtypes = [ctypes.c_long, ctypes.c_bool]
        self.get_type.restype, self.get_type.argtypes = ctypes.c_long, [ctypes.c_long]
        self.set_type.argtypes = [ctypes.c_long, ctypes.c_long]

    COLOR, GRAYSCALE = 1, 1  # category 1 is Color; type 1 within it Grayscale (MADisplayFilterCopySystemFilter's bit 0)

    def state(self):
        return self.get_enabled(self.COLOR), self.get_type(self.COLOR)

    def restore(self, state):
        # In the order that never shows the other filter for a moment
        enabled, kind = state
        if enabled:
            self.set_type(self.COLOR, kind)
            self.set_enabled(self.COLOR, True)
        else:
            self.set_enabled(self.COLOR, False)
            self.set_type(self.COLOR, kind)


def check_eye_test(args):
    display_id = args.display or Quartz.CGMainDisplayID()
    display = pipeline.Display.live(display_id)
    expected = predictions(display)
    if args.answer:
        answers = [float(a) / 100 for a in args.answer.split(",")]
        print(f"{display.name}, tiles numbered ×100:")
        for (name, (encoded, light)), answer in zip(expected.items(), answers):
            print(f"  {name:5}  seen {answer * 100:3.0f}   encoded values {encoded * 100:5.1f}   light {light * 100:5.1f}")
        off_encoded = max(abs(a - e[0]) for a, e in zip(answers, expected.values()))
        off_light = max(abs(a - e[1]) for a, e in zip(answers, expected.values()))
        print(f"most off: {off_encoded * 100:.1f} if encoded, {off_light * 100:.1f} if light → the matrix multiplies "
              f"{'light' if off_light < off_encoded else 'encoded values'}")
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
    try:
        filters.set_type(filters.COLOR, filters.GRAYSCALE)
        filters.set_enabled(filters.COLOR, True)
        print(f"Grayscale is on for {args.seconds:.0f} s: in each row, which tile's square disappears?", flush=True)
        run_for(args.seconds)
    finally:
        filters.restore(before)
        window.close()
    print("Color Filters are back as they were:", "on" if before[0] else "off", f"(type {before[1]})")
    print("Then: check.py eye-test --answer RED,GREEN,BLUE")


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
    args = parser.parse_args()
    {"colour": check_colour, "dark-layer": check_dark_layer, "eye-test": check_eye_test, "brightness": check_brightness}[args.check](args)


if __name__ == "__main__":
    main()
