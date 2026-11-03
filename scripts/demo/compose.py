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
#   2. pipeline.shown() turns the whole screen into the light the display gives off with that frame's
#      settings, as log.json has them: Color Tint's hue and intensity, and the display's brightness.
#   3. A camera films it: a crop of the screen, moving and zooming as the scene's "camera" says, scaled
#      in light, as a camera's sensor would take it.
#   4. pipeline.to_video() makes the colours of the video, which ffmpeg encodes at fixed settings, so
#      the same recording gives the same files, byte for byte.
#
#   compose.py <scene>          writes into build/demo/<scene>/, for each of the scene's cameras (16x9,
#                               9x16): <scene>-<camera>.mp4, the master, in Display P3 (HEVC, 10 bits, its
#                               colour tagged so players show the display's own red), <scene>-<camera>-srgb.mp4
#                               (H.264, 8 bits, sRGB, for where P3 isn't shown, its deepest reds clipped),
#                               and stills/<camera>-NNNN.png of the first, middle and last frames, in P3
#   compose.py check <scene>    compares the recorder's first frame, with the window server's shadow and
#                               rims added, against the window server's own picture of the popover over the
#                               same desktop (make-demo.sh --check records both into build/demo/<scene>/check/)
#   compose.py verify <scene>   decodes the videos as macOS's players do (AVFoundation, colour matched to
#                               Display P3) and compares them with the colours they were made from
#   compose.py hues <scene>     for a scene that moves Tint: the masters' desktop, decoded, at red, yellow,
#                               green, cyan, blue and magenta, against pipeline.shown() with MediaAccessibility's
#                               matrix for the Tint slider's value on each of those frames
#
# A scene's camera (scenes/*.json, "camera") has, for each shape, the video's size in pixels and keys:
# at a time, the middle of what's filmed and its height, in points on the display, kept on the display.
# Between two keys it moves along the later one's easing (linear, easeIn, easeOut or easeInOut, as Core
# Animation's), zooming by the same ratio each moment, about the point that's in the same place in both.
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
      same desktop (desktop/window-server.png), where that has it: not above the window, where the
      menu bar is, which only the shadow reaches."""

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
        # The window server's picture over the desktop, where it has one
        self.picture = np.full(with_shadow.shape[:2] + (3,), np.nan, np.float32)
        desktop = self.folder / "desktop"
        self.desktop = json.loads((desktop / "about.json").read_text()) if (desktop / "about.json").exists() else None
        if self.desktop:
            taken, taken_icc = read_png(desktop / "window-server.png")
            if taken_icc != display.profile.data:
                raise SystemExit(f"{desktop}'s pictures aren't in {display.name}'s colours; delete it and make the shot again")
            window = [round(v * self.scale) for v in self.desktop["window"]]
            top, left = m - window[1], m - window[0]
            y0, x0 = max(top, 0), max(left, 0)
            y1, x1 = min(top + taken.shape[0], self.picture.shape[0]), min(left + taken.shape[1], self.picture.shape[1])
            self.picture[y0:y1, x0:x1] = taken[y0 - top:y1 - top, x0 - left:x1 - left, :3]

    def backdrop(self):
        """The desktop the window server's picture of the popover over the desktop was taken over, in
        Display P3, and where on the desktop, in points"""
        if not self.desktop:
            return None, None
        return read_png(self.folder / "desktop" / "backdrop.png")[0][..., :3], self.desktop.get("canvas")

    def add(self, picture, origin, window, background):
        """Puts it into `picture`, a part of the screen in the display's colours whose top left is at pixel
        `origin`, with the frame in it already, for a window whose top left is at pixel `window`, over
        `background`, the same part of the desktop without the popover"""
        top, left = window[1] - self.margin - origin[1], window[0] - self.margin - origin[0]
        y0, x0 = max(top, 0), max(left, 0)
        y1, x1 = min(top + self.shadow.shape[0], picture.shape[0]), min(left + self.shadow.shape[1], picture.shape[1])
        if y0 >= y1 or x0 >= x1:
            return
        part = (slice(y0 - top, y1 - top), slice(x0 - left, x1 - left))
        shadow = self.shadow[part]
        over = shadow[..., :3] + (1 - shadow[..., 3:]) * background[y0:y1, x0:x1]
        taken = self.picture[part]
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
        pixels, icc = read_png(self.folder / desktop["image"])
        self.desktop = to_display(pixels, icc, self.display)
        appearances = {frame["system"]["appearance"] for frame in self.log["frames"]}
        if len(appearances) != 1:
            raise SystemExit(f"{scene} changes the appearance, which changes the popover's edge: the window server's picture of it is for one")
        self.window_server = WindowServerLayer(appearances.pop(), desktop["popover"][2:], self.display)
        # Its picture of the popover's edge has to be over this desktop, with the popover in this place
        taken, place = self.window_server.backdrop()
        x, y, w, h = self.canvas
        if taken is None or place != desktop["canvas"] or not np.array_equal(taken, pixels[y:y + h, x:x + w, :3]):
            raise SystemExit(f"The window server's picture of the popover in {self.window_server.folder}/desktop isn't over this desktop: make-demo.sh takes it")
        self.pointer = Pointer(self.display, self.scale, self.log["pointer"]["hotSpot"])

    def settings(self, frame):
        """Color Tint as (hue, intensity) or None, and the display's brightness, on `frame`"""
        system = self.log["frames"][frame]["system"]
        tint = (system["hue"], system["intensity"]) if system["colorFilter"] else None
        brightness = next(d["brightness"] for d in system["displays"] if d["id"] == self.log["desktop"]["display"])
        return tint, brightness

    def screen(self, frame, region):
        """The screen's encoded values, in the display's colours, in `region` (left, top, right, bottom,
        in pixels): the desktop with the frame in its place, the window server's shadow round it, and
        the pointer"""
        x0, y0, x1, y1 = region
        picture = self.desktop[y0:y1, x0:x1].copy()
        cx, cy, cw, ch = self.canvas
        ix0, iy0, ix1, iy1 = max(x0, cx), max(y0, cy), min(x1, cx + cw), min(y1, cy + ch)
        if ix0 < ix1 and iy0 < iy1:
            pixels, icc = read_png(self.folder / "frames" / f"{frame:04d}.png")
            if np.any(pixels[..., 3] < 1):
                raise SystemExit(f"Frame {frame} is see-through; it wasn't recorded over the desktop")
            part = pixels[iy0 - cy:iy1 - cy, ix0 - cx:ix1 - cx, :3]
            picture[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0] = to_display(part, icc, self.display)
        self.window_server.add(picture, (x0, y0), self.window[:2], self.desktop[y0:y1, x0:x1])
        if pointer := self.log["frames"][frame].get("pointer"):
            canvas = self.log["desktop"]["canvas"]
            self.pointer.draw(picture, (x0, y0), (canvas[0] + pointer["x"], canvas[1] + pointer["y"]))
        return np.clip(picture, 0, 1)

    def light(self, frame, region):
        """What the display gives off in `region` on `frame`, with its settings then"""
        tint, brightness = self.settings(frame)
        return pipeline.shown(self.screen(frame, region), self.display, tint, brightness)


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
    def __init__(self, name, spec, display_size):
        self.name = name
        self.size = spec["size"]
        self.aspect = self.size[0] / self.size[1]
        self.display = display_size
        self.keys = [(key["at"], self.rect(key), key.get("easing", "easeInOut")) for key in sorted(spec["keys"], key=lambda key: key["at"])]

    def rect(self, key):
        """A key's view, in the video's shape, at most the display's size, and on it: left, top, width, height"""
        width, height = key["height"] * self.aspect, key["height"]
        if width > self.display[0]:
            width, height = self.display[0], self.display[0] / self.aspect
        if height > self.display[1]:
            width, height = self.display[1] * self.aspect, self.display[1]
        x = min(max(key["centre"][0] - width / 2, 0), self.display[0] - width)
        y = min(max(key["centre"][1] - height / 2, 0), self.display[1] - height)
        return x, y, width, height

    def view(self, time):
        """What's filmed at `time`: left, top, right and bottom, in points on the display. Between two keys
        the view zooms by the same ratio each moment, about the one point that's in the same place in
        both views, so an edge they share stays put; with no zoom, it moves straight across."""
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


def film(shot, camera, frame):
    """The camera's picture of the light the screen gives off on `frame`, scaled in light with a Lanczos
    filter, kept from ringing: each pixel between the least and the most light of the screen's pixels
    round where it's taken from (scaled the same way from the screen's darkest and brightest in each
    3 by 3), so sharp text gets no dark or bright halo"""
    from scipy import ndimage
    view = [v * shot.scale for v in camera.view(frame / shot.fps)]
    reach = 3 * max(1.0, (view[2] - view[0]) / camera.size[0]) + 2
    region = (max(int(math.floor(view[0] - reach)), 0), max(int(math.floor(view[1] - reach)), 0),
              min(int(math.ceil(view[2] + reach)), shot.desktop.shape[1]), min(int(math.ceil(view[3] + reach)), shot.desktop.shape[0]))
    light = shot.light(frame, region).astype(np.float32)
    box = (view[0] - region[0], view[1] - region[1], view[2] - region[0], view[3] - region[1])
    size = tuple(camera.size)
    def scaled(channel, how):
        return np.asarray(Image.fromarray(np.ascontiguousarray(channel), "F").resize(size, how, box=box))
    channels = []
    for c in range(3):
        sharp = scaled(light[..., c], Image.Resampling.LANCZOS)
        least = scaled(ndimage.minimum_filter(light[..., c], 3), Image.Resampling.BILINEAR)
        most = scaled(ndimage.maximum_filter(light[..., c], 3), Image.Resampling.BILINEAR)
        channels.append(np.clip(sharp, least, most))
    return np.dstack(channels).astype(np.float64)


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
    """One frame of one camera: its planes for each video, and its P3 values if it's kept as a still"""
    camera, frame, still = task
    light = film(_shot, camera, frame)
    videos = {}
    for suffix, (space, bits, _) in VIDEOS.items():
        values = pipeline.to_video(light, _shot.display, space, 16).astype(np.float64) / 65535
        videos[suffix] = ycbcr(values, bits)
        if still and space == "display-p3":
            videos["still"] = np.round(values * 255).astype(np.uint8)
    return videos


def compose(scene, folder, workers):
    shot = Shot(scene, folder)
    cameras = [Camera(name, spec, shot.size) for name, spec in shot.scene["camera"].items()]
    stills = {0, shot.count // 2, shot.count - 1}
    (shot.folder / "stills").mkdir(exist_ok=True)
    with multiprocessing.get_context("spawn").Pool(workers, _open, (scene, folder)) as pool:
        for camera in cameras:
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
                waiting.append((frame, pool.apply_async(_render, ((camera, frame, frame in stills),))))
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
    layer.add(ours, (0, 0), window[:2], background)
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
        camera = Camera(name, spec, shot.size)
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
        camera = Camera(name, spec, shot.size)
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
    parser.add_argument("command", nargs="?", choices=["check", "verify", "hues"])
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
    else:
        compose(args.scene, args.folder, args.workers)


if __name__ == "__main__":
    main()
