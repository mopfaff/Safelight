#!/usr/bin/env python3
# Makes a demo shot's videos from what scripts/make-demo.sh recorded, so the screen in them is what the
# display gives off, as macOS shows it:
#
#   1. Each frame of the popover (frames/NNNN.png, Display P3, its glass drawn over the desktop) goes in
#      its place on the desktop (desktop.png), and what the window server draws round the popover's
#      window, which a frame doesn't have, is added: its shadow and its rims, from the window server's
#      own pictures of them (build/demo/window-server/, `-windowServer` in the recorder). Outside the
#      window's shape, which those pictures give, it's the desktop: Core Animation draws a faint
#      shadow of the glass there (8% at most) that the window server doesn't. Then macOS's arrow,
#      where log.json has the pointer, over everything, as the pointer is: before step 2, as the colour
#      filter tints it with the rest (red Color Tint turned its white outline red, seen on the screen,
#      check.py pointer, 2026-11-03). As the window server does, this is all in the display's own
#      colour space, blending its encoded values.
#      When the appearance changes (recorder/AppearanceTransition.swift), the desktop is in layers instead:
#      the wallpaper between its pictures for Light and Dark, the menu bar in its appearance over it, and
#      what the window server draws round the popover, taken over each picture, blended as the wallpaper
#      is. Over all that but the pointer, while macOS shows it, its picture of the screen from when the
#      change began, fading out: the screen as it was on the frame drawn last before.
#      The popover's window grows and shrinks with what's in it (log.json's "window" on each frame), and
#      what the window server draws round it is taken for each of its sizes.
#      In a scene with a clock of its own, the menu bar's clock says the time of day on each frame: its
#      picture for that minute (clock/), in the menu bar's appearance, over the menu bar, which is without it.
#   2. pipeline.shown() turns the whole screen into the light the display gives off with that frame's
#      settings, as log.json has them: Color Tint's hue and intensity, and the display's brightness.
#      For a scene with "otherDisplays": true, the Mac's other displays are on the stage as well, each
#      with its own desktop (desktop-<number>.png, which nothing on changes) and its own brightness, through
#      its own pipeline: the Dell's gamma table, the Studio Display's backlight (Stage). For a scene with
#      "nightShift", the same screen is on the stage again, as it is with Night Shift on instead (Stage).
#   3. A camera films it: a crop of the stage, moving and zooming as the scene's "camera" says, scaled
#      in light, as a camera's sensor would take it. A camera can have panes, each a part of the video
#      filming the stage on its own (a close view of the popover above both displays whole, say).
#   4. pipeline.to_video() makes the colours of the video, which ffmpeg encodes at fixed settings, so
#      the same recording gives the same files, byte for byte.
#
#   compose.py <scene>          writes into build/demo/<scene>/, for each of the scene's cameras (16x9,
#                               9x16): <scene>-<camera>.mp4, the master, in Display P3 (HEVC, 10 bits, its
#                               colour tagged so players show the display's own red), <scene>-<camera>-srgb.mp4
#                               (H.264, 8 bits, sRGB, for where P3 isn't shown, its deepest reds clipped),
#                               and stills/<camera>-NNNN.png of the first, middle and last frames, and any
#                               others the scene lists in "stills", in P3
#   compose.py check <scene>    compares the recorder's first frame, with the window server's shadow and
#                               rims added, against the window server's own picture of the popover over the
#                               same desktop (make-demo.sh --check records both into build/demo/<scene>/check/)
#   compose.py verify <scene>   decodes the videos as macOS's players do (AVFoundation, colour matched to
#                               Display P3) and compares them with the colours they were made from
#   compose.py needs <scene>    the window server's pictures of the popover over the desktop the recording
#                               needs, a line for each: the popover's appearance, the wallpaper's picture
#                               under it, and YES or NO, whether the displays are adjusted independently,
#                               which sets the popover's size (make-demo.sh takes them)
#   compose.py schedule <scene> for a scene with a schedule: the settings Safelight has on each frame against
#                               the schedule's for the minute its clock reads, worked out here as ColorKeyframe
#                               does, and against each keyframe's own at its time; what it has set the Mac to,
#                               within what it leaves unwritten; and when the appearance changes over
#   compose.py hues <scene>     for a scene that moves Tint: the masters' desktop, decoded, at red, yellow,
#                               green, cyan, blue and magenta, against pipeline.shown() with MediaAccessibility's
#                               matrix for the Tint slider's value on each of those frames
#
# A scene's camera (scenes/*.json, "camera") has, for each shape, the video's size in pixels and keys:
# at a time, the middle of what's filmed and its height, in points on the stage (the popover's display's,
# from its top left), kept on the stage. Between two keys it moves along the later one's easing (linear,
# easeIn, easeOut or easeInOut, as Core Animation's), zooming by the same ratio each moment, about the
# point that's in the same place in both. Or, instead of keys, "panes": each a "rect" of the video
# (left, top, width, height, in pixels) and keys of its own; the rest of the video is black, but for a
# pane's "label", a plain line of text over it (in SF Pro, light grey), where it's needed to read the
# shot (captions are the edit's).
#
# A scene with "nightShift": {"strength": S} puts the same screen again to the left of the popover's,
# GAP points away, as it is with Night Shift on at its slider's S (1 is More Warm) and Safelight's
# filter off: the desktop with the popover closed (desktop-closed.png), no pointer, at the same
# brightness, through Night Shift's matrix as CoreBrightness makes it (pipeline.night_shift_matrix).
#
# Needs what pipeline.py needs, and ffmpeg with libx265 and libx264.
import argparse, collections, json, math, multiprocessing, subprocess, sys
from pathlib import Path
import numpy as np
import Quartz
from PIL import Image
import pipeline

ROOT = Path(__file__).resolve().parents[2]
SCENES = ROOT / "scripts" / "demo" / "scenes"
BUILD = ROOT / "build" / "demo"
WINDOW_SERVER = BUILD / "window-server"
P3 = bytes(Quartz.CGColorSpaceCopyICCData(Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceDisplayP3)))


def read_png(path):
    """A PNG's values, 0...1, with its alpha if it has one, and its ICC profile"""
    image = Image.open(path)
    icc = image.info.get("icc_profile")
    mode = "RGBA" if "A" in image.getbands() else "RGB"
    return np.asarray(image.convert(mode), np.float32) / 255, icc


def to_display(rgb, icc, display):
    """Encoded values in the colour space of `icc` matched to the display's, by CoreGraphics, as the
    window server matches a window's"""
    if icc == display.profile.data:
        return rgb.astype(np.float32)
    return pipeline.cg_convert(rgb.astype(np.float64), icc, display.profile.data).astype(np.float32)


# --- What the window server adds ------------------------------------------------------------------

class WindowServerLayer:
    """What the window server draws round the popover's window, which the recorder's frames don't have,
    from its own pictures of it (build/demo/window-server/<appearance>-<size>/, which the recorder takes
    with -windowServer), in the display's colours. Measured in Dark over Sonoma on 3 November 2026:
    - 3 pixels or more outside the window's shape (where its picture alone, alone.png, has any alpha),
      it's the window server's shadow (with-shadow.png, the window over nothing with its shadow) over
      the desktop: within 2 levels of the window server's picture. The recorder draws a fainter shadow
      of the glass there (8% at most), which the window server doesn't.
    - 2 pixels or more inside it, it's the recorder's frame as it is: its glass is within 3 levels.
    - In between, in a ring 4 or 5 pixels wide, the window server draws its dark rim over the recorder's
      own, and its rims under the glass, which the glass's edge picks up: up to 51 levels off that
      shadow or the recorder's frame. The ring is the same on every frame while the popover and the
      desktop round it don't change, so it's the window server's own picture of the popover over the
      same desktop (desktop/window-server.png, or desktop-2/… for another desktop: `picture_over`), where that
      has it: not above the window, where the menu bar is, which only the shadow reaches."""

    RING_OUTSIDE, RING_INSIDE = 3, 2

    def __init__(self, appearance, window_size, display):
        from scipy import ndimage
        self.folder = WINDOW_SERVER / f"{appearance}-{int(window_size[0])}x{int(window_size[1])}"
        if not (self.folder / "about.json").exists():
            raise SystemExit(f"There's no picture of the window server's shadow in {self.folder}: make-demo.sh takes it")
        about = json.loads((self.folder / "about.json").read_text())
        with_shadow, icc = read_png(self.folder / "with-shadow.png")
        alone, alone_icc = read_png(self.folder / "alone.png")
        if icc != display.profile.data or alone_icc != display.profile.data:
            raise SystemExit(f"{self.folder}'s pictures aren't in {display.name}'s colours; delete it and make the shot again")
        self.scale = about["scale"]
        self.margin = int(about["margin"] * self.scale)
        self.shadow = with_shadow
        # Which part each pixel round the window is in, from the window's shape
        shape = np.zeros(with_shadow.shape[:2], bool), np.zeros(with_shadow.shape[:2], bool)
        m = self.margin
        shape[0][m:m + alone.shape[0], m:m + alone.shape[1]] = alone[..., 3] > 0
        shape[1][m:m + alone.shape[0], m:m + alone.shape[1]] = alone[..., 3] == 1
        touched, whole = shape
        self.ring = ((touched & ~whole) | (whole & (ndimage.distance_transform_edt(whole) < self.RING_INSIDE))
                     | (~touched & (ndimage.distance_transform_edt(~touched) < self.RING_OUTSIDE)))
        self.outside = ~touched & ~self.ring
        self.display = display

    def picture_over(self, backdrop, canvas):
        """The window server's picture of the popover over the desktop `backdrop` (the canvas round it, in
        Display P3, 0...1) at `canvas` on the desktop, in points, round the window as the shadow is,
        with nothing (NaN) where it has nothing: from whichever of the folders it's taken into (desktop,
        desktop-2, …) was taken over that"""
        for desktop in sorted(self.folder.glob("desktop*")):
            if not (desktop / "about.json").exists():
                continue
            about = json.loads((desktop / "about.json").read_text())
            if about.get("canvas") != canvas or not np.array_equal(read_png(desktop / "backdrop.png")[0][..., :3], backdrop):
                continue
            taken, taken_icc = read_png(desktop / "window-server.png")
            if taken_icc != self.display.profile.data:
                raise SystemExit(f"{desktop}'s pictures aren't in {self.display.name}'s colours; delete it and make the shot again")
            picture = np.full(self.shadow.shape[:2] + (3,), np.nan, np.float32)
            window = [round(v * self.scale) for v in about["window"]]
            m = self.margin
            top, left = m - window[1], m - window[0]
            y0, x0 = max(top, 0), max(left, 0)
            y1, x1 = min(top + taken.shape[0], picture.shape[0]), min(left + taken.shape[1], picture.shape[1])
            picture[y0:y1, x0:x1] = taken[y0 - top:y1 - top, x0 - left:x1 - left, :3]
            return picture
        raise SystemExit(f"There's no picture of the window server's of the popover over this desktop in {self.folder}: make-demo.sh takes it")

    def add(self, picture, origin, window, background, ring):
        """Puts it into `picture`, a part of the screen in the display's colours whose top left is at pixel
        `origin`, with the frame in it already, for a window whose top left is at pixel `window`, over
        `background`, the same part of the desktop without the popover, with `ring` as the window
        server's picture of its edge"""
        top, left = window[1] - self.margin - origin[1], window[0] - self.margin - origin[0]
        y0, x0 = max(top, 0), max(left, 0)
        y1, x1 = min(top + self.shadow.shape[0], picture.shape[0]), min(left + self.shadow.shape[1], picture.shape[1])
        if y0 >= y1 or x0 >= x1:
            return
        part = (slice(y0 - top, y1 - top), slice(x0 - left, x1 - left))
        shadow = self.shadow[part]
        over = shadow[..., :3] + (1 - shadow[..., 3:]) * background[y0:y1, x0:x1]
        taken = ring[part]
        ring = self.ring[part]
        has = ring & ~np.isnan(taken[..., 0])
        target = picture[y0:y1, x0:x1]
        target[self.outside[part] | (ring & ~has)] = over[self.outside[part] | (ring & ~has)]
        target[has] = taken[has]

class Pointer:
    """macOS's arrow, drawn as the recorder draws it (NSCursor.arrow's picture, its hot spot at the
    pointer), in the display's colours, into the screen the colour filter's applied to, as it tints
    the pointer too"""

    def __init__(self, display, scale, hot_spot):
        import AppKit
        self.appkit = AppKit
        # AppKit only has its cursors once there's an app
        AppKit.NSApplication.sharedApplication().setActivationPolicy_(AppKit.NSApplicationActivationPolicyProhibited)
        self.image = AppKit.NSCursor.arrowCursor().image()
        self.hot_spot = hot_spot
        self.scale = scale
        self.space = Quartz.CGColorSpaceCreateWithICCData(display.profile.data)

    def draw(self, picture, origin, point):
        """Over `picture`, whose top left is at pixel `origin`, with its hot spot at `point`, in points on
        the desktop"""
        AppKit = self.appkit
        size = self.image.size()
        x, y = point[0] - self.hot_spot[0], point[1] - self.hot_spot[1]
        left, top = math.floor(x * self.scale) - 1, math.floor(y * self.scale) - 1
        w, h = math.ceil(size.width * self.scale) + 3, math.ceil(size.height * self.scale) + 3
        info = Quartz.kCGImageAlphaPremultipliedLast | Quartz.kCGBitmapFloatComponents | Quartz.kCGBitmapByteOrder32Little
        context = Quartz.CGBitmapContextCreate(None, w, h, 32, w * 16, self.space, info)
        # In points from the desktop's top left
        Quartz.CGContextTranslateCTM(context, 0, h)
        Quartz.CGContextScaleCTM(context, self.scale, -self.scale)
        Quartz.CGContextTranslateCTM(context, -left / self.scale, -top / self.scale)
        AppKit.NSGraphicsContext.saveGraphicsState()
        AppKit.NSGraphicsContext.setCurrentContext_(AppKit.NSGraphicsContext.graphicsContextWithCGContext_flipped_(context, True))
        self.image.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(((x, y), (size.width, size.height)), AppKit.NSZeroRect,
                                                                               AppKit.NSCompositingOperationSourceOver, 1, True, None)
        AppKit.NSGraphicsContext.restoreGraphicsState()
        arrow = np.frombuffer(Quartz.CGBitmapContextGetData(context).as_buffer(h * w * 16), np.float32).reshape(h, w, 4)
        top, left = top - origin[1], left - origin[0]
        y0, x0, y1, x1 = max(top, 0), max(left, 0), min(top + h, picture.shape[0]), min(left + w, picture.shape[1])
        if y0 < y1 and x0 < x1:
            part = arrow[y0 - top:y1 - top, x0 - left:x1 - left]
            picture[y0:y1, x0:x1] = part[..., :3] + (1 - part[..., 3:]) * picture[y0:y1, x0:x1]


# --- The shot -------------------------------------------------------------------------------------

class Shot:
    """A recorded scene on the desktop, frame by frame on the screen as the display shows it"""

    def __init__(self, scene, folder=None):
        self.name = scene
        self.folder = Path(folder) if folder else BUILD / scene
        self.scene = json.loads((SCENES / f"{scene}.json").read_text())
        self.log = json.loads((self.folder / "log.json").read_text())
        desktop = self.log.get("desktop")
        if not desktop:
            raise SystemExit(f"{scene} wasn't recorded on the desktop; give its scene \"desktop\": true")
        self.display = pipeline.Display.live(desktop["display"])
        if self.display.kind != pipeline.BACKLIGHT:
            raise SystemExit(f"{self.display.name} isn't a display whose backlight Safelight dims, as the desktop's is")
        self.scale = desktop["scale"]
        self.size = desktop["size"]
        self.canvas = [round(v * self.scale) for v in desktop["canvas"]]
        self.window = [round(v * self.scale) for v in desktop["popover"]]
        self.count = len(self.log["frames"])
        self.fps = self.log["fps"]
        frames = self.log["frames"]
        x, y, w, h = self.canvas
        # The desktop as one picture while it and the popover's appearance don't change, as recorded before
        # scenes could change the appearance; in layers otherwise (desktop_state)
        states = {(f["popover"], f["desktop"]["wallpaper"], f["desktop"]["menuBar"]) if "desktop" in f else None for f in frames}
        # The menu bar's clock for each minute, with a clock of the scene's: its pictures in Light and Dark,
        # matched to the display's colours with their alpha, and where it goes, in pixels
        self.clocks = {}
        for clock in desktop.get("clocks") or []:
            pictures = []
            for appearance in ("light", "dark"):
                pixels, icc = read_png(self.folder / clock[appearance])
                pictures.append(np.dstack([to_display(pixels[..., :3], icc, self.display), pixels[..., 3:]]))
            frame = [round(v * self.scale) for v in clock["frame"]]
            if pictures[0].shape[:2] != (frame[3], frame[2]):
                raise SystemExit(f"{clock['light']} isn't the size of its place in the menu bar")
            self.clocks[clock["title"]] = (dict(zip(("light", "dark"), pictures)), frame)
        self.layered = len(states) > 1 or bool(self.clocks)
        self.layers = {}
        # What the window server draws round the popover, for each appearance and size it has, and its
        # picture of the popover's edge over each picture of the wallpaper under it
        self.window_servers, self.rings = {}, {}
        if not self.layered:
            pixels, icc = read_png(self.folder / desktop["image"])
            self.desktop = to_display(pixels, icc, self.display)
            for popover, size in dict.fromkeys(self.popover_state(frame) for frame in range(self.count)):
                self.window_servers[(popover, size)] = WindowServerLayer(popover, size, self.display)
                # Its picture of the popover's edge has to be over this desktop, with the popover in this place
                self.rings[(popover, size, None)] = self.window_servers[(popover, size)].picture_over(pixels[y:y + h, x:x + w, :3], desktop["canvas"])
        else:
            for appearance in ("light", "dark"):
                wallpaper, icc = read_png(self.folder / f"wallpaper-{appearance}.png")
                menu_bar, menu_icc = read_png(self.folder / f"menubar-{appearance}.png")
                # The menu bar's colours, matched to the display's, kept with their alpha, as the window
                # server puts it over the wallpaper
                self.layers[appearance] = (to_display(wallpaper[..., :3], icc, self.display),
                                           np.dstack([to_display(menu_bar[..., :3], menu_icc, self.display), menu_bar[..., 3:]]))
            self.desktop = self.layers["light"][0]
            for popover, wallpaper, size in self.needs():
                if (popover, size) not in self.window_servers:
                    self.window_servers[(popover, size)] = WindowServerLayer(popover, size, self.display)
                backdrop = read_png(self.folder / "backdrops" / f"wallpaper-{wallpaper}-menubar-{popover}.png")[0][..., :3]
                self.rings[(popover, size, wallpaper)] = self.window_servers[(popover, size)].picture_over(backdrop, desktop["canvas"])
        self.pointer = Pointer(self.display, self.scale, self.log["pointer"]["hotSpot"])
        # For a scene with "nightShift": the same screen with Night Shift on instead of Safelight's filter,
        # the popover closed, at the strength of its slider the scene gives (1 is More Warm), its matrix
        # made by CoreBrightness's own code (pipeline.night_shift_matrix)
        self.night_shift = self.scene.get("nightShift")
        if self.night_shift:
            if self.layered:
                raise SystemExit("Night Shift's screen is drawn from desktop-closed.png, which doesn't change: keep the appearance")
            pixels, icc = read_png(self.folder / "desktop-closed.png")
            self.closed = to_display(pixels[..., :3], icc, self.display)
            self.night_shift_cct = pipeline.night_shift_cct(self.night_shift.get("strength", 1))
            self.night_shift_matrix = pipeline.night_shift_matrix(self.night_shift_cct)
        self.stage = Stage(self)

    def popover_state(self, frame):
        """The popover's appearance on `frame`, and its window's size, in points"""
        record = self.log["frames"][frame]
        appearance = record.get("popover") or self.log["frames"][0]["system"]["appearance"]
        size = tuple(record["window"][2:]) if "window" in record else tuple(self.log["desktop"]["popover"][2:])
        return appearance, size

    def needs(self):
        """The window server's pictures of the popover over the desktop the frames need: for each, the
        popover's appearance, the wallpaper's picture under it, light or dark, while it shows any of it
        (the menu bar has the popover's appearance, as both change when the app's told), and its window's
        size, with whether the displays are adjusted independently then, which gives the popover that size"""
        needed, independently = [], {}
        for number, frame in enumerate(self.log["frames"]):
            popover, desktop = frame.get("popover"), frame.get("desktop")
            if not popover or not desktop:
                continue
            if desktop["menuBar"] != popover:
                raise SystemExit(f"Frame {frame['frame']} has the menu bar in {desktop['menuBar']} and the popover in {popover}; no picture of the window server's has that")
            size = self.popover_state(number)[1]
            split = frame["app"].get("adjustsDisplaysIndependently", False)
            if independently.setdefault(size, split) != split:
                raise SystemExit(f"The popover is {size[0]:g}×{size[1]:g} points with the displays adjusted independently and not; the window server's picture can't be taken")
            for wallpaper, shows in (("light", desktop["wallpaper"] < 1), ("dark", desktop["wallpaper"] > 0)):
                if shows and (popover, wallpaper, size) not in needed:
                    needed.append((popover, wallpaper, size))
        self.independently = independently
        return needed

    def settings(self, frame, display=None):
        """Color Tint as (hue, intensity) or None, and the brightness of `display` (the popover's unless
        another's number is given), on `frame`"""
        system = self.log["frames"][frame]["system"]
        tint = (system["hue"], system["intensity"]) if system["colorFilter"] else None
        display = self.log["desktop"]["display"] if display is None else display
        brightness = next(d["brightness"] for d in system["displays"] if d["id"] == display)
        return tint, brightness

    def desktop_state(self, frame, region):
        """The desktop without the popover in `region` on `frame`, in the display's colours: its wallpaper
        between its pictures for Light and Dark as the log has it, and over it the menu bar in its
        appearance, as the window server puts one over the other, blending their encoded values"""
        x0, y0, x1, y1 = region
        if not self.layered:
            return self.desktop[y0:y1, x0:x1]
        state = self.log["frames"][frame]["desktop"]
        dark = state["wallpaper"]
        light_wallpaper, dark_wallpaper = self.layers["light"][0][y0:y1, x0:x1], self.layers["dark"][0][y0:y1, x0:x1]
        wallpaper = light_wallpaper if dark == 0 else dark_wallpaper if dark == 1 else (1 - dark) * light_wallpaper + dark * dark_wallpaper
        menu_bar = self.layers[state["menuBar"]][1][y0:y1, x0:x1]
        desktop = menu_bar[..., :3] * menu_bar[..., 3:] + (1 - menu_bar[..., 3:]) * wallpaper
        # The clock as it says the frame's time, over what's under it, in the menu bar's appearance
        if title := self.log["frames"][frame].get("menuBarClock"):
            pictures, (cx, cy, cw, ch) = self.clocks[title]
            ix0, iy0, ix1, iy1 = max(x0, cx), max(y0, cy), min(x1, cx + cw), min(y1, cy + ch)
            if ix0 < ix1 and iy0 < iy1:
                clock = pictures[state["menuBar"]][iy0 - cy:iy1 - cy, ix0 - cx:ix1 - cx]
                under = desktop[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0]
                desktop[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0] = clock[..., :3] * clock[..., 3:] + (1 - clock[..., 3:]) * under
        return desktop

    def ring(self, frame):
        """The window server's picture of the popover's edge on `frame`, for its appearance and size: over
        the wallpaper's picture for Light, for Dark, or as much of each as the wallpaper shows, as the glass
        shows what's under it"""
        popover, size = self.popover_state(frame)
        if not self.layered:
            return self.rings[(popover, size, None)]
        dark = self.log["frames"][frame]["desktop"]["wallpaper"]
        if dark == 0:
            return self.rings[(popover, size, "light")]
        if dark == 1:
            return self.rings[(popover, size, "dark")]
        return (1 - dark) * self.rings[(popover, size, "light")] + dark * self.rings[(popover, size, "dark")]

    def screen(self, frame, region, pointer=True):
        """The screen's encoded values, in the display's colours, in `region` (left, top, right, bottom,
        in pixels): the desktop with the frame in its place and the window server's shadow round it, under
        macOS's picture of the screen while the appearance changes, and the pointer, unless left out"""
        x0, y0, x1, y1 = region
        background = self.desktop_state(frame, region)
        picture = background.copy()
        cx, cy, cw, ch = self.canvas
        ix0, iy0, ix1, iy1 = max(x0, cx), max(y0, cy), min(x1, cx + cw), min(y1, cy + ch)
        if ix0 < ix1 and iy0 < iy1:
            pixels, icc = read_png(self.folder / "frames" / f"{frame:04d}.png")
            if np.any(pixels[..., 3] < 1):
                raise SystemExit(f"Frame {frame} is see-through; it wasn't recorded over the desktop")
            part = pixels[iy0 - cy:iy1 - cy, ix0 - cx:ix1 - cx, :3]
            picture[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0] = to_display(part, icc, self.display)
        record = self.log["frames"][frame]
        self.window_servers[self.popover_state(frame)].add(picture, (x0, y0), self.window[:2], background, self.ring(frame))
        # macOS's picture of the screen, taken as the change began, over everything but the pointer, as
        # the window server puts it over what's under it, blending their encoded values
        if taken := record.get("screenPicture"):
            opacity = taken["opacity"]
            picture = opacity * self.screen(taken["frame"], region, pointer=False) + (1 - opacity) * picture
        if pointer and (place := record.get("pointer")):
            canvas = self.log["desktop"]["canvas"]
            self.pointer.draw(picture, (x0, y0), (canvas[0] + place["x"], canvas[1] + place["y"]))
        return np.clip(picture, 0, 1)

    def light(self, frame, region):
        """What the display gives off in `region` on `frame`, with its settings then"""
        tint, brightness = self.settings(frame)
        return pipeline.shown(self.screen(frame, region), self.display, tint, brightness)


class Stage:
    """Every display the shot shows, where it's filmed: the popover's display at its place, in its points
    from its top left, and for a scene with "otherDisplays": true, the Mac's others beside it, each where
    the displays' arrangement has it and at its real size beside the first, from the size in millimetres
    each tells macOS (from its EDID, not measured), its pixels square, at the width it gives. A display
    beside another as arranged is put `GAP`
    points away from it, for the room between two screens (which isn't measured); along the edge they
    share it's as far down (or across) as arranged. Each display's desktop is lit by its own pipeline with
    its own brightness. Light is relative to each display's own white: 1 is its white at full brightness,
    the Dell's as the Studio Display's, though the Dell's white is dimmer than the Studio Display's 600
    nits (by how much wasn't measured), so the shot shows how far each is dimmed from its own full
    brightness, not how bright one looks beside the other. Around and between them it's black."""

    GAP = 48
    MARGIN = 60

    def __init__(self, shot):
        self.shot = shot
        width, height = shot.size
        self.displays = [StageDisplay(shot.display, (0, 0, width, height), shot.scale, None, shot.light)]
        if shot.night_shift:
            if shot.log["desktop"].get("others"):
                raise SystemExit("Night Shift's screen goes where another display would: not with \"otherDisplays\"")
            # The same display again, GAP to the left, showing the desktop with the popover closed and
            # Night Shift on, at the brightness the popover's display has on each frame
            def light(frame, region):
                x0, y0, x1, y1 = region
                brightness = shot.settings(frame)[1]
                return pipeline.shown(shot.closed[y0:y1, x0:x1], shot.display, None, brightness, night_shift=shot.night_shift_matrix)
            self.displays.append(StageDisplay(shot.display, (-self.GAP - width, 0, width, height), shot.scale, "Night Shift", light))
        desktop = shot.log["desktop"]
        others = desktop.get("others") or []
        if others:
            per_point = desktop["millimetres"][0] / width
            for other in others:
                display = pipeline.Display.live(other["display"])
                pixels, icc = read_png(shot.folder / other["image"])
                encoded = to_display(pixels[..., :3], icc, display)
                x, y, w, h = other["frame"]
                scale = other["millimetres"][0] / w / per_point
                sw, sh = w * scale, h * scale
                sx = -self.GAP - sw if x + w <= 0 else width + self.GAP if x >= width else x
                sy = -self.GAP - sh if y + h <= 0 else height + self.GAP if y >= height else y
                def light(frame, region, encoded=encoded, display=display, number=other["display"]):
                    x0, y0, x1, y1 = region
                    tint, brightness = shot.settings(frame, number)
                    return pipeline.shown(encoded[y0:y1, x0:x1], display, tint, brightness)
                self.displays.append(StageDisplay(display, (sx, sy, sw, sh), other["scale"] / scale, other["name"], light))
        if len(self.displays) > 1:
            left = min(d.rect[0] for d in self.displays) - self.MARGIN
            top = min(d.rect[1] for d in self.displays) - self.MARGIN
            right = max(d.rect[0] + d.rect[2] for d in self.displays) + self.MARGIN
            bottom = max(d.rect[1] + d.rect[3] for d in self.displays) + self.MARGIN
            self.bounds = (left, top, right, bottom)
        else:
            self.bounds = (0, 0, width, height)


class StageDisplay:
    """A display on the stage: where it is (left, top, width, height, in stage points), its pixels to a
    stage point, and the light it gives off in a region of its pixels on a frame"""

    def __init__(self, display, rect, scale, name, light):
        self.display, self.rect, self.scale, self.name, self.light = display, rect, scale, name, light
        self.pixels = (round(rect[2] * scale), round(rect[3] * scale))


# --- The camera -----------------------------------------------------------------------------------

def bezier(x1, y1, x2, y2, x):
    """The cubic Bézier from (0, 0) to (1, 1) with these control points, at time x, solved by bisection
    as DemoScene.Easing does"""
    def point(a, b, s):
        return 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
    low, high = 0.0, 1.0
    for _ in range(60):
        middle = (low + high) / 2
        if point(x1, x2, middle) < x:
            low = middle
        else:
            high = middle
    return point(y1, y2, (low + high) / 2)


EASINGS = {"linear": lambda t: t, "easeIn": lambda t: bezier(0.42, 0, 1, 1, t),
           "easeOut": lambda t: bezier(0, 0, 0.58, 1, t), "easeInOut": lambda t: bezier(0.42, 0, 0.58, 1, t)}


class Camera:
    """A pane of a video filming the stage: where it is in the video (left, top, width, height, in
    pixels) and what it films when"""

    def __init__(self, name, spec, bounds, rect=None, label=None):
        self.name = name
        self.size = spec["size"]
        self.rect = rect or (0, 0, *self.size)
        self.label = label
        self.aspect = self.rect[2] / self.rect[3]
        self.bounds = bounds
        self.keys = [(key["at"], self.view_rect(key), key.get("easing", "easeInOut")) for key in sorted(spec["keys"], key=lambda key: key["at"])]

    @classmethod
    def all(cls, name, spec, bounds):
        """A video's panes: each of its "panes", or the whole of it"""
        if "panes" not in spec:
            return [cls(name, spec, bounds)]
        return [cls(name, {"size": spec["size"], "keys": pane["keys"]}, bounds, tuple(pane["rect"]), pane.get("label")) for pane in spec["panes"]]

    def view_rect(self, key):
        """A key's view, in the pane's shape: left, top, width, height. At most the size that takes in the
        whole stage, and on it, or, across which it's wider than the stage (the stage's shape not being the
        pane's), with the stage in the middle"""
        left, top, right, bottom = self.bounds
        most = max(right - left, (bottom - top) * self.aspect)
        width, height = min(key["height"] * self.aspect, most), min(key["height"], most / self.aspect)
        x = min(max(key["centre"][0] - width / 2, left), right - width) if width <= right - left else (left + right - width) / 2
        y = min(max(key["centre"][1] - height / 2, top), bottom - height) if height <= bottom - top else (top + bottom - height) / 2
        return x, y, width, height

    def view(self, time):
        """What's filmed at `time`: left, top, right and bottom, in points on the stage. Between two keys
        the view zooms by the same ratio each moment, about the one point that's in the same place in both
        views, so an edge they share stays put; with no zoom, it moves straight across."""
        if time <= self.keys[0][0]:
            x, y, w, h = self.keys[0][1]
        elif time >= self.keys[-1][0]:
            x, y, w, h = self.keys[-1][1]
        else:
            later = next(i for i, key in enumerate(self.keys) if key[0] > time)
            (at0, (x0, y0, w0, h0), _), (at1, (x1, y1, w1, h1), easing) = self.keys[later - 1], self.keys[later]
            progress = EASINGS[easing](min(max((time - at0) / (at1 - at0), 0), 1))
            if abs(w1 - w0) < 1e-9:
                x, y, w, h = x0 + (x1 - x0) * progress, y0 + (y1 - y0) * progress, w0, h0
            else:
                w = math.exp(math.log(w0) + (math.log(w1) - math.log(w0)) * progress)
                h = w / self.aspect
                # The point at the same place in both: x0 + u·w0 = x1 + u·w1
                fx, fy = (x1 * w0 - x0 * w1) / (w0 - w1), (y1 * h0 - y0 * h1) / (h0 - h1)
                x, y = fx - (fx - x0) * w / w0, fy - (fy - y0) * h / h0
        return x, y, x + w, y + h


def film(shot, cameras, frame):
    """The video's picture of the light the stage gives off on `frame`: each of `cameras`, its panes,
    filming its part of the video"""
    cameras = cameras if isinstance(cameras, list) else [cameras]
    width, height = cameras[0].size
    picture = np.zeros((height, width, 3))
    for camera in cameras:
        x, y, w, h = camera.rect
        picture[y:y + h, x:x + w] = film_pane(shot, camera, frame)
        if camera.label:
            # In the black above the pane, so on no display: light as the display's white gives it
            lx, ly, ink = label(camera)
            picture[ly:ly + ink.shape[0], lx:lx + ink.shape[1]] = shot.display.profile.decode(np.repeat(ink[..., None], 3, axis=2))
    return picture


LABEL_FONT = "/System/Library/Fonts/SFNS.ttf"
LABEL_GREY = 0.85
_labels = {}


def label(camera):
    """A pane's label as Pillow draws it, in SF Pro Medium, its size 6% of the pane's height, light grey
    over black, centred over the pane, the bottom of its letters 4% of the pane's height above it: where
    its picture goes in the video (left, top), and its encoded values, 0...1"""
    key = (camera.label, camera.rect)
    if key not in _labels:
        from PIL import ImageDraw, ImageFont
        x, y, w, h = camera.rect
        font = ImageFont.truetype(LABEL_FONT, round(h * 0.06))
        font.set_variation_by_name("Medium")
        left, top, right, bottom = font.getbbox(camera.label)
        image = Image.new("L", (right - left, bottom - top))
        ImageDraw.Draw(image).text((-left, -top), camera.label, font=font, fill=255)
        lx, ly = x + (w - (right - left)) // 2, y - round(h * 0.04) - (bottom - top)
        if ly < 0:
            raise SystemExit(f"No room above the pane for its label \"{camera.label}\"")
        _labels[key] = (lx, ly, np.asarray(image, np.float64) / 255 * LABEL_GREY)
    return _labels[key]


def film_pane(shot, camera, frame):
    """A pane's picture of the light the stage gives off on `frame`: each display it films scaled in
    light with a Lanczos filter, kept from ringing: each pixel between the least and the most light of
    the display's pixels round where it's taken from (scaled the same way from the display's darkest and
    brightest in each 3 by 3), so sharp text gets no dark or bright halo. Where a display's edge is in the
    picture, it's scaled with black beyond it, as the stage is there."""
    from scipy import ndimage
    view = camera.view(frame / shot.fps)
    width, height = camera.rect[2], camera.rect[3]
    per_point = width / (view[2] - view[0])
    picture = np.zeros((height, width, 3))
    for display in shot.stage.displays:
        dx, dy, dw, dh = display.rect
        ix0, iy0, ix1, iy1 = max(view[0], dx), max(view[1], dy), min(view[2], dx + dw), min(view[3], dy + dh)
        if ix0 >= ix1 or iy0 >= iy1:
            continue
        # The pane's pixels the display is in, and where they are on the display, in its pixels
        u0, v0 = max(int(math.floor((ix0 - view[0]) * per_point)), 0), max(int(math.floor((iy0 - view[1]) * per_point)), 0)
        u1, v1 = min(int(math.ceil((ix1 - view[0]) * per_point)), width), min(int(math.ceil((iy1 - view[1]) * per_point)), height)
        k = display.scale
        # On the stage, the pane's pixel edges: the view's own where they're the pane's
        def across(u):
            return view[0] if u == 0 else view[2] if u == width else view[0] + u / per_point
        def down(v):
            return view[1] if v == 0 else view[3] if v == height else view[1] + v / per_point
        box = [(across(u0) - dx) * k, (down(v0) - dy) * k, (across(u1) - dx) * k, (down(v1) - dy) * k]
        reach = 3 * max(1.0, (box[2] - box[0]) / (u1 - u0)) + 2
        # Black beyond each edge of the display that's in the picture; elsewhere what the display has
        # round the view, as far as it goes
        pw, ph = display.pixels
        beyond = [view[0] < dx - 1e-6, view[1] < dy - 1e-6, view[2] > dx + dw + 1e-6, view[3] > dy + dh + 1e-6]
        want = [int(math.floor(box[0] - reach)), int(math.floor(box[1] - reach)), int(math.ceil(box[2] + reach)), int(math.ceil(box[3] + reach))]
        region = [max(want[0], 0), max(want[1], 0), min(want[2], pw), min(want[3], ph)]
        light = display.light(frame, tuple(region)).astype(np.float32)
        pad = [region[0] - want[0] if beyond[0] else 0, region[1] - want[1] if beyond[1] else 0,
               want[2] - region[2] if beyond[2] else 0, want[3] - region[3] if beyond[3] else 0]
        if any(pad):
            light = np.pad(light, ((pad[1], pad[3]), (pad[0], pad[2]), (0, 0)))
        origin = (region[0] - pad[0], region[1] - pad[1])
        source = (box[0] - origin[0], box[1] - origin[1], box[2] - origin[0], box[3] - origin[1])
        size = (u1 - u0, v1 - v0)
        def scaled(channel, how):
            return np.asarray(Image.fromarray(np.ascontiguousarray(channel), "F").resize(size, how, box=source))
        channels = []
        for c in range(3):
            sharp = scaled(light[..., c], Image.Resampling.LANCZOS)
            least = scaled(ndimage.minimum_filter(light[..., c], 3), Image.Resampling.BILINEAR)
            most = scaled(ndimage.maximum_filter(light[..., c], 3), Image.Resampling.BILINEAR)
            channels.append(np.clip(sharp, least, most))
        picture[v0:v1, u0:u1] += np.dstack(channels).astype(np.float64)
    return picture


# --- The videos -----------------------------------------------------------------------------------

# Each kind of video: the colour space its values are in, its bits, and how ffmpeg encodes it. The tags
# say Display P3's primaries (SMPTE EG 432-1) or sRGB's (BT.709), the sRGB tone curve (IEC 61966-2-1)
# both use, and BT.709's luma and chroma at video's limited range, as the values are made here.
VIDEOS = {
    "": ("display-p3", 10, ["-c:v", "libx265", "-preset", "slow", "-crf", "12", "-tag:v", "hvc1",
                            "-x265-params", "log-level=error:lookahead-slices=0:colorprim=smpte432:transfer=iec61966-2-1:colormatrix=bt709:range=limited:chromaloc=0"]),
    "-srgb": ("srgb", 8, ["-c:v", "libx264", "-preset", "slow", "-crf", "16", "-profile:v", "high",
                          "-x264-params", "colorprim=bt709:transfer=iec61966-2-1:colormatrix=bt709:range=tv:chromaloc=0"]),
}


def ycbcr(values, bits):
    """Encoded R'G'B' (0...1) as BT.709 Y'CbCr at video's limited range, 4:2:0 with each chroma value at
    the left of its two columns, between its two rows (as MPEG-2, and players assume unless told): the
    planes, as raw little-endian bytes for ffmpeg"""
    r, g, b = values[..., 0], values[..., 1], values[..., 2]
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    cb, cr = (b - y) / 1.8556, (r - y) / 1.5748
    def subsample(c):
        rows = (c[0::2] + c[1::2]) / 2
        padded = np.concatenate([rows[:, :1], rows, rows[:, -1:]], axis=1)
        return (padded[:, 0:-2:2] + 2 * padded[:, 1:-1:2] + padded[:, 2::2]) / 4
    scale = 1 << (bits - 8)
    dtype = "<u2" if bits > 8 else np.uint8
    planes = [np.round((16 + 219 * y) * scale), np.round((128 + 224 * subsample(cb)) * scale), np.round((128 + 224 * subsample(cr)) * scale)]
    return b"".join(np.clip(p, 0, (1 << bits) - 1).astype(dtype).tobytes() for p in planes)


def ffmpeg(path, camera, fps, space, bits, settings):
    """ffmpeg encoding the planes it's sent as they are. The raw frames are tagged with the colours
    they're in, as the video is: untagged, ffmpeg takes them for BT.601 and converts them to the
    BT.709 the video is tagged with, which took Display P3's red to 0.91."""
    pixel_format = "yuv420p10le" if bits == 10 else "yuv420p"
    primaries = "smpte432" if space == "display-p3" else "bt709"
    colours = ["-color_primaries", primaries, "-color_trc", "iec61966-2-1", "-colorspace", "bt709", "-color_range", "tv", "-chroma_sample_location", "left"]
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", pixel_format,
               "-s", f"{camera.size[0]}x{camera.size[1]}", "-r", str(fps), *colours, "-i", "-",
               *settings, "-pix_fmt", pixel_format, *colours, "-movflags", "+write_colr", "-map_metadata", "-1",
               "-fflags", "+bitexact", "-flags:v", "+bitexact", str(path)]
    return subprocess.Popen(command, stdin=subprocess.PIPE)


_shot = None


def _open(scene, folder):
    global _shot
    _shot = Shot(scene, folder)


def _render(task):
    """One frame of one video: its planes for each kind, and its P3 values if it's kept as a still"""
    cameras, frame, still = task
    light = film(_shot, cameras, frame)
    videos = {}
    for suffix, (space, bits, _) in VIDEOS.items():
        values = pipeline.to_video(light, _shot.display, space, 16).astype(np.float64) / 65535
        videos[suffix] = ycbcr(values, bits)
        if still and space == "display-p3":
            videos["still"] = np.round(values * 255).astype(np.uint8)
    return videos


def compose(scene, folder, workers):
    shot = Shot(scene, folder)
    videos = [Camera.all(name, spec, shot.stage.bounds) for name, spec in shot.scene["camera"].items()]
    stills = {0, shot.count // 2, shot.count - 1} | set(shot.scene.get("stills", []))
    (shot.folder / "stills").mkdir(exist_ok=True)
    with multiprocessing.get_context("spawn").Pool(workers, _open, (scene, folder)) as pool:
        for cameras in videos:
            camera = cameras[0]
            name = camera.name.replace(":", "x")
            encoders = {suffix: ffmpeg(shot.folder / f"{scene}-{name}{suffix}.mp4", camera, shot.fps, space, bits, settings)
                        for suffix, (space, bits, settings) in VIDEOS.items()}

            def write(frame, videos):
                for suffix, encoder in encoders.items():
                    encoder.stdin.write(videos[suffix])
                if "still" in videos:
                    pipeline.save(str(shot.folder / "stills" / f"{name}-{frame:04d}.png"), videos["still"])
                print(f"\r{name}: {frame + 1}/{shot.count}", end="", flush=True)

            # Written in order, with only so many frames waiting at once
            waiting = collections.deque()
            for frame in range(shot.count):
                waiting.append((frame, pool.apply_async(_render, ((cameras, frame, frame in stills),))))
                if len(waiting) > 2 * workers:
                    done, result = waiting.popleft()
                    write(done, result.get())
            while waiting:
                done, result = waiting.popleft()
                write(done, result.get())
            for suffix, encoder in encoders.items():
                encoder.stdin.close()
                if encoder.wait() != 0:
                    raise SystemExit(f"ffmpeg couldn't encode {scene}-{name}{suffix}.mp4")
            print(f"\r{name}: {', '.join(f'{scene}-{name}{suffix}.mp4' for suffix in VIDEOS)}")


# --- Checks ---------------------------------------------------------------------------------------

def report(name, ours, theirs):
    diff = np.abs(ours.astype(np.int32) - theirs.astype(np.int32)).max(axis=-1)
    shares = ", ".join(f"{np.mean(diff <= n) * 100:.2f}% within {n}" for n in (0, 1, 2, 3, 6))
    print(f"{name}: {diff.size} pixels, {shares}, most off {diff.max()}")


def check(folder):
    """The recorder's first frame over the desktop (recorder.png), with what the window server draws
    round the popover put in (WindowServerLayer), against the window server's own picture of it over
    the same desktop (window-server.png), in the display's colours: in the glass, round it, in the ring
    at the window's edge (which WindowServerLayer takes from an earlier picture of the window server's,
    so there this only shows it draws the same again), and without the window server's parts"""
    folder = Path(folder)
    about = json.loads((folder / "about.json").read_text())
    display = pipeline.Display.live(about["display"])
    recorder, recorder_icc = read_png(folder / "recorder.png")
    backdrop, backdrop_icc = read_png(folder / "backdrop.png")
    theirs, theirs_icc = read_png(folder / "window-server.png")
    if theirs_icc != display.profile.data:
        raise SystemExit("The window server's picture isn't in the display's colours")
    layer = WindowServerLayer(about["appearance"], about["window"][2:], display)
    scale = about["scale"]
    window = [round(v * scale) for v in about["window"]]
    background = to_display(backdrop[..., :3], backdrop_icc, display)
    plain = to_display(recorder[..., :3], recorder_icc, display)
    ours = plain.copy()
    layer.add(ours, (0, 0), window[:2], background, layer.picture_over(backdrop[..., :3], about.get("canvas")))
    level = lambda values: np.round(np.clip(values, 0, 1) * 255)
    theirs = level(theirs[..., :3])
    # Each pixel's part, from the layer's, which goes round the window
    m = layer.margin
    def part(mask):
        out = np.zeros(theirs.shape[:2], bool)
        top, left = window[1] - m, window[0] - m
        y0, x0 = max(top, 0), max(left, 0)
        y1, x1 = min(top + mask.shape[0], out.shape[0]), min(left + mask.shape[1], out.shape[1])
        out[y0:y1, x0:x1] = mask[y0 - top:y1 - top, x0 - left:x1 - left]
        return out
    ring, outside = part(layer.ring), part(layer.outside)
    inside = ~ring & ~outside
    print(f"{about['appearance']}, the popover over the desktop against the window server's picture of it:")
    report("  in the glass, the recorder's frame", level(ours)[inside], theirs[inside])
    report("  round it, the window server's shadow", level(ours)[outside], theirs[outside])
    report("  in the ring, the earlier picture", level(ours)[ring], theirs[ring])
    report("  everywhere", level(ours), theirs)
    report("  the recorder's frame alone, round it and in the ring", level(plain)[~inside], theirs[~inside])
    diff = np.abs(level(ours) - theirs).max(axis=-1)
    Image.fromarray(np.clip(diff * 16, 0, 255).astype(np.uint8)).save(folder / "difference.png")


def decode(path, count, wanted):
    """The frames numbered in `wanted` of a video of `count` frames, decoded by AVFoundation, as QuickTime
    Player and Safari decode them, with their colours matched to Display P3: each one's number and values"""
    import AVFoundation, CoreMedia
    asset = AVFoundation.AVURLAsset.URLAssetWithURL_options_(Foundation_url(path), None)
    track = asset.tracksWithMediaType_(AVFoundation.AVMediaTypeVideo)[0]
    settings = {Quartz.kCVPixelBufferPixelFormatTypeKey: Quartz.kCVPixelFormatType_64RGBAHalf,
                AVFoundation.AVVideoColorPropertiesKey: {
                    AVFoundation.AVVideoColorPrimariesKey: AVFoundation.AVVideoColorPrimaries_P3_D65,
                    AVFoundation.AVVideoTransferFunctionKey: AVFoundation.AVVideoTransferFunction_IEC_sRGB,
                    AVFoundation.AVVideoYCbCrMatrixKey: AVFoundation.AVVideoYCbCrMatrix_ITU_R_709_2}}
    reader = AVFoundation.AVAssetReader.alloc().initWithAsset_error_(asset, None)[0]
    output = AVFoundation.AVAssetReaderTrackOutput.alloc().initWithTrack_outputSettings_(track, settings)
    reader.addOutput_(output)
    reader.startReading()
    frame = 0
    while (sample := output.copyNextSampleBuffer()) is not None:
        if frame in wanted:
            yield frame, pixel_buffer(CoreMedia.CMSampleBufferGetImageBuffer(sample))
        frame += 1
    if frame != count:
        raise SystemExit(f"{path.name} has {frame} frames, not {count}")


def verify(scene, folder):
    """Each video decoded by AVFoundation, as QuickTime Player and Safari decode it, with its colours
    matched to Display P3, against the values it was made from, on its stills' frames"""
    shot = Shot(scene, folder)
    for name, spec in shot.scene["camera"].items():
        camera = Camera.all(name, spec, shot.stage.bounds)
        name = name.replace(":", "x")
        for suffix, (space, bits, _) in VIDEOS.items():
            path = shot.folder / f"{scene}-{name}{suffix}.mp4"
            for frame, decoded in decode(path, shot.count, {0, shot.count // 2, shot.count - 1}):
                made = pipeline.to_video(film(shot, camera, frame), shot.display, "display-p3", 16).astype(np.float64) / 65535
                if space == "srgb":
                    # Clipped to sRGB first, as that copy is
                    srgb = pipeline.to_video(film(shot, camera, frame), shot.display, "srgb", 16).astype(np.float64) / 65535
                    made = pipeline.cg_convert(srgb, bytes(Quartz.CGColorSpaceCopyICCData(Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceSRGB))), P3)
                report(f"{path.name} frame {frame}", np.round(decoded * 255), np.round(np.clip(made, 0, 1) * 255))


def hues(scene, folder, size=40):
    """Color Tint in the masters at a few hues, against what pipeline.shown() gives from MediaAccessibility's
    matrix at the Tint slider's value then (not the hue log.json has the system at): on the frames where
    the slider is nearest red, yellow, green, cyan, blue, magenta and red again, the mean colour, in
    light, of each `size`-point square of the desktop that every one of those frames films, away from
    the popover's window and its shadow and below the menu bar"""
    shot = Shot(scene, folder)
    frames = shot.log["frames"]
    if "Tint" not in frames[0]["sliders"]:
        raise SystemExit(f"{scene}'s log has no Tint slider")
    tint = [frame["sliders"]["Tint"]["value"] for frame in frames]
    wanted = {min(range(shot.count), key=lambda i: abs(tint[i] - hue)): hue for hue in (0, 60, 120, 180, 240, 300, 360)}
    p3 = pipeline.named_profile(Quartz.kCGColorSpaceDisplayP3)
    x, y, w, h = shot.log["desktop"]["popover"]
    popover = (x - 48, y - 48, x + w + 48, y + h + 48)
    for name, spec in shot.scene["camera"].items():
        camera = Camera(name, spec, shot.stage.bounds)
        views = {frame: camera.view(frame / shot.fps) for frame in wanted}
        left, top = max(v[0] for v in views.values()) + 4, max(max(v[1] for v in views.values()) + 4, 40)
        right, bottom = min(v[2] for v in views.values()) - 4, min(v[3] for v in views.values()) - 4
        squares = [(sx, sy, sx + size, sy + size) for sx in np.arange(left, right - size, size) for sy in np.arange(top, bottom - size, size)
                   if sx + size <= popover[0] or sx >= popover[2] or sy + size <= popover[1] or sy >= popover[3]]
        path = shot.folder / f"{scene}-{name.replace(':', 'x')}.mp4"
        print(f"{path.name}, {len(squares)} squares of {size} points:")
        for frame, decoded in decode(path, shot.count, set(wanted)):
            matrix = pipeline.tint_matrix(tint[frame] / 360, frames[frame]["system"]["intensity"])
            brightness = shot.settings(frame)[1]
            view = views[frame]
            ours, theirs = [], []
            for sx0, sy0, sx1, sy1 in squares:
                region = [round(v * shot.scale) for v in (sx0, sy0, sx1, sy1)]
                light = pipeline.shown(shot.screen(frame, region), shot.display, (tint[frame] / 360, frames[frame]["system"]["intensity"]), brightness)
                theirs.append(pipeline.to_video(light.reshape(-1, 3).mean(0)[None, None], shot.display, "display-p3", 16)[0, 0] / 65535)
                # The video's pixels whose middles are in the square
                u0, u1 = [math.ceil((s - view[0]) * camera.size[0] / (view[2] - view[0]) - 0.5) for s in (sx0, sx1)]
                v0, v1 = [math.ceil((s - view[1]) * camera.size[1] / (view[3] - view[1]) - 0.5) for s in (sy0, sy1)]
                ours.append(p3.encode(p3.decode(decoded[v0:v1, u0:u1]).reshape(-1, 3).mean(0)[None, None])[0, 0])
            ours, theirs = np.round(np.array(ours) * 255), np.round(np.array(theirs) * 255)
            diff = np.abs(ours - theirs).max(axis=-1)
            print(f"  frame {frame}, Tint {tint[frame]:.1f}° (nearest {wanted[frame]}°), matrix {np.round(np.diag(matrix), 4)}: "
                  f"most off {diff.max():.0f} levels, mean {diff.mean():.2f}; a square {theirs[0].astype(int)} made, {ours[0].astype(int)} decoded")


def schedule_settings(keyframes, minute):
    """The settings a schedule has reached `minute` minutes after midnight, worked out as Safelight's
    ColorKeyframe.settings(in:at:) does, in its single-precision floats: intensity (0 where the filter's off),
    tint, brightness and whether it's Dark, from the scene's keyframes"""
    f = np.float32
    frames = sorted(({"minute": int(k["time"][:2]) * 60 + int(k["time"][3:5]), **k} for k in keyframes), key=lambda k: k["minute"])
    start_index = max((i for i, k in enumerate(frames) if k["minute"] <= minute), default=None)
    start = frames[start_index if start_index is not None else -1]
    end = frames[((start_index if start_index is not None else -1) + 1) % len(frames)]
    start_minute = float(start["minute"]) - (1440 if start_index is None else 0)
    end_minute = float(end["minute"])
    if end_minute <= start_minute:
        end_minute += 1440
    progress = f((minute - start_minute) / (end_minute - start_minute))
    start_tint = f(start["tint"]) if start["colorFilter"] or not end["colorFilter"] else f(end["tint"])
    end_tint = f(end["tint"]) if end["colorFilter"] or not start["colorFilter"] else f(start["tint"])
    change = f(np.fmod(f(end_tint - start_tint), f(360)))
    if change > 180:
        change = f(change - f(360))
    elif change < -180:
        change = f(change + f(360))
    tint = f(np.fmod(f(start_tint + f(change * progress)), f(360)))
    if tint < 0:
        tint = f(tint + f(360))
    start_intensity = f(start["intensity"]) if start["colorFilter"] else f(0)
    end_intensity = f(end["intensity"]) if end["colorFilter"] else f(0)
    intensity = f(start_intensity + f(f(end_intensity - start_intensity) * progress))
    brightness = f(f(start["brightness"]) + f(f(f(end["brightness"]) - f(start["brightness"])) * progress))
    return intensity, tint, brightness, start["appearance"] == "dark"


def check_schedule(scene, folder):
    """Safelight's settings on each frame of a scene with a schedule against the schedule's for the minute
    the clock reads then (its timer sets them on each whole minute), worked out as Safelight does
    (schedule_settings); what it has set the Mac to, which it only writes when it's changed by more than
    a little (Color Tint by 0.0001, the brightness by 0.001); each keyframe's own settings on the frame
    its minute is reached; and the appearance: the app's from the keyframe's minute, the system's from
    when the change is posted (AppearanceTransition.swift) """
    folder = Path(folder) if folder else BUILD / scene
    spec = json.loads((SCENES / f"{scene}.json").read_text())
    log = json.loads((folder / "log.json").read_text())
    keyframes = spec.get("schedule")
    if not keyframes or "clock" not in spec:
        raise SystemExit(f"{scene} has no schedule and clock of its own")
    display = log["desktop"]["display"]
    low = np.float32(0.25)
    worst = collections.defaultdict(float)
    reached = {}
    switches = []
    last_dark = None
    for record in log["frames"]:
        hours, minutes, seconds = record["timeOfDay"].split(":")
        minute = int(hours) * 60 + int(minutes)
        intensity, tint, brightness, dark = schedule_settings(keyframes, minute)
        on = intensity >= low
        app, system = record["app"], record["system"]
        expected = {"intensity": float(min(max(intensity, low), np.float32(1))), "tint": float(tint), "brightness": float(brightness)}
        for name, value in expected.items():
            worst["app " + name] = max(worst["app " + name], abs(app[name] - value))
        if app["isColorFilterOn"] != bool(on) or app["isDarkAppearance"] != dark:
            raise SystemExit(f"Frame {record['frame']} ({record['timeOfDay']}): the app has the filter {'on' if app['isColorFilterOn'] else 'off'} "
                             f"and {'Dark' if app['isDarkAppearance'] else 'Light'}, the schedule {'on' if on else 'off'} and {'Dark' if dark else 'Light'}")
        if system["colorFilter"] != bool(on):
            raise SystemExit(f"Frame {record['frame']} ({record['timeOfDay']}): the Mac has the filter {'on' if system['colorFilter'] else 'off'}")
        worst["system hue"] = max(worst["system hue"], abs(system["hue"] - float(np.float32(tint / np.float32(360)))))
        worst["system intensity"] = max(worst["system intensity"], abs(system["intensity"] - expected["intensity"]))
        shown = next(d["brightness"] for d in system["displays"] if d["id"] == display)
        worst["system brightness"] = max(worst["system brightness"], abs(shown - expected["brightness"]))
        for keyframe in keyframes:
            if keyframe["time"] == f"{hours}:{minutes}" and keyframe["time"] not in reached:
                reached[keyframe["time"]] = (record, keyframe)
        if system["appearance"] != last_dark:
            switches.append((record["frame"], record["timeOfDay"], system["appearance"]))
            last_dark = system["appearance"]
    print(f"{scene}: {len(log['frames'])} frames from {log['frames'][0]['timeOfDay']} to {log['frames'][-1]['timeOfDay']}, against the schedule's settings for each minute:")
    limits = {"app intensity": 1e-6, "app tint": 1e-4, "app brightness": 1e-6, "system hue": 1e-4, "system intensity": 1e-4, "system brightness": 1e-3}
    for name, value in worst.items():
        print(f"  {name}: most off {value:.2g}{'' if value <= limits[name] else '  TOO FAR'}")
    for time, (record, keyframe) in sorted(reached.items()):
        app, system = record["app"], record["system"]
        shown = next(d["brightness"] for d in system["displays"] if d["id"] == display)
        exact = (app["isColorFilterOn"] == keyframe["colorFilter"] and app["tint"] == float(np.float32(keyframe["tint"]))
                 and app["brightness"] == float(np.float32(keyframe["brightness"])) and app["isDarkAppearance"] == (keyframe["appearance"] == "dark")
                 and (not keyframe["colorFilter"] or app["intensity"] == float(np.float32(keyframe["intensity"]))))
        print(f"  keyframe {time} reached on frame {record['frame']} ({record['time']:.3f} s into the shot, {record['timeOfDay']}): "
              f"app {'on' if app['isColorFilterOn'] else 'off'} {app['intensity']:.4f} {app['tint']:.2f}° {app['brightness']:.4f} {'Dark' if app['isDarkAppearance'] else 'Light'}, "
              f"Mac hue {system['hue'] * 360:.2f}° {system['intensity']:.4f} brightness {shown:.4f} {system['appearance']}: "
              f"{'the keyframe exactly' if exact else 'NOT the keyframe'}")
    for frame, time, appearance in switches[1:]:
        print(f"  the Mac's appearance {appearance} from frame {frame} ({time})")
    if any(value > limits[name] for name, value in worst.items()):
        raise SystemExit("Safelight's settings are off the schedule's")


def Foundation_url(path):
    import Foundation
    return Foundation.NSURL.fileURLWithPath_(str(path))


def pixel_buffer(buffer):
    """A 64RGBAHalf pixel buffer's red, green and blue"""
    Quartz.CVPixelBufferLockBaseAddress(buffer, 1)
    try:
        width, height = Quartz.CVPixelBufferGetWidth(buffer), Quartz.CVPixelBufferGetHeight(buffer)
        row = Quartz.CVPixelBufferGetBytesPerRow(buffer)
        data = Quartz.CVPixelBufferGetBaseAddress(buffer).as_buffer(row * height)
        values = np.frombuffer(data, np.float16).reshape(height, row // 2)[:, :width * 4].reshape(height, width, 4)
        return values[..., :3].astype(np.float64)
    finally:
        Quartz.CVPixelBufferUnlockBaseAddress(buffer, 1)


def main():
    parser = argparse.ArgumentParser(description="Makes a recorded demo shot's videos.")
    parser.add_argument("command", nargs="?", choices=["check", "verify", "hues", "needs", "schedule"])
    parser.add_argument("scene")
    parser.add_argument("--folder", help="where the recording is, and the videos go: build/demo/<scene>/ unless given")
    parser.add_argument("--workers", type=int, default=min(multiprocessing.cpu_count(), 8))
    args = parser.parse_args()
    if args.command == "check":
        check(args.folder or BUILD / args.scene / "check")
    elif args.command == "verify":
        verify(args.scene, args.folder)
    elif args.command == "hues":
        hues(args.scene, args.folder)
    elif args.command == "schedule":
        check_schedule(args.scene, args.folder)
    elif args.command == "needs":
        log = Shot.__new__(Shot)
        log.log = json.loads(((Path(args.folder) if args.folder else BUILD / args.scene) / "log.json").read_text())
        for popover, wallpaper, size in log.needs():
            print(popover, wallpaper, "YES" if log.independently[size] else "NO")
    else:
        compose(args.scene, args.folder, args.workers)


if __name__ == "__main__":
    main()
