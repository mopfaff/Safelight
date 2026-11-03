#!/usr/bin/env python3
# What a display shows of a frame once macOS has applied Safelight's settings to it: the Color Tint
# filter, the brightness, and on an iPad used with Sidecar, the dark layer. A screen recording or a
# screenshot never has the filter or the brightness in it, as macOS applies them after the frame is
# drawn, on its way to the panel. So the demo videos apply them to recorded frames here, the way macOS
# does, as worked out from macOS itself (2026-11-03, macOS 27 on Apple silicon):
#
#   1. WindowServer draws each display's frame in that display's own colour space (its ICC profile,
#      which screencapture tags its pictures with), blending on the encoded values. Sidecar's dark
#      layer (GammaManager.setDimmingWindow) is a window like any other, so it's part of the frame.
#   2. The display coprocessor (DCP) takes each value of the frame through the gamma table
#      (CGSetDisplayTransferByTable: Safelight's software dimming, each value × brightness), turns it
#      into light with the profile's tone curve, and multiplies the light by the accessibility colour
#      matrix: MediaAccessibility's own, which universalaccessd hands to WindowServer
#      (SLSSetAccessibilityAdjustments) and QuartzCore to the DCP
#      (IOMFBDisplay::set_framebuffer_ax_matrix → IOMobileFramebufferSwapSetColorMatrix, location 2).
#      An iPad used with Sidecar is sent the frame as it is: QuartzCore's displays other than
#      IOMFBDisplay ignore the matrix, and the gamma table never reaches it.
#   3. The backlight. DisplayServices' slider goes straight into the Studio Display's HID brightness
#      (CBDisplayModuleHIDLegacy setDeviceBrightness: slider × the element's logical maximum), which
#      is in hundredths of a nit, 400...60000, so its white gives off 600 nits × slider, at least 4.
#
# Light comes out linear, in the display's own primaries, 1 being its white at full brightness, and
# to_video() turns it into a video's colours. The display's deepest red is outside sRGB's (and so
# Rec. 709's), so the video is made in Display P3, and an sRGB copy clips what it can't show.
#
#   pipeline.py FRAME.png OUT.png [--display ID] [--tint HUE,INTENSITY] [--brightness B] [--space display-p3|srgb]
#
# writes what display ID (the main display if left out) shows of FRAME, a picture in that display's
# colour space, with Color Tint at HUE (0...1, 0 red) and INTENSITY, at brightness B. Needs NumPy,
# Pillow and PyObjC (pip install numpy pillow pyobjc).
import argparse, ctypes, ctypes.util, io, struct
from dataclasses import dataclass
import numpy as np
import Foundation
import objc
import Quartz
from PIL import Image

# Whether the DCP multiplies light by the colour matrix ("linear"), or the encoded values ("encoded").
# It's light: under Grayscale, red, green and blue matched greys of 58.4, 79.2 and 36.6 on the screen,
# not 30, 59 and 11 (check.py eye-test, 2026-11-03). "encoded" is kept to compare the two.
MATRIX_DOMAIN = "linear"


# --- MediaAccessibility ---------------------------------------------------------------------------

class _Matrix(ctypes.Structure):
    _fields_ = [("m", ctypes.c_double * 9)]


_ma = ctypes.CDLL("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility")
for _name in ("MADisplayFilterCreateSingleColor", "MADisplayFilterCreateGrayscale"):
    getattr(_ma, _name).restype = ctypes.c_void_p
    getattr(_ma, _name).argtypes = [ctypes.c_double] * 4
# The matrix comes back as a struct of 9 doubles, which ctypes takes from the caller's buffer (x8), as C does
_ma.MADisplayFilterGetMatrix.restype = _Matrix
_ma.MADisplayFilterGetMatrix.argtypes = [ctypes.c_void_p]
_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
_cf.CFRelease.argtypes = [ctypes.c_void_p]


def _filter_matrix(filter_ref):
    try:
        m = np.array(_ma.MADisplayFilterGetMatrix(filter_ref).m, np.float64).reshape(3, 3)
    finally:
        _cf.CFRelease(filter_ref)
    # It reaches the DCP as floats (SkyLight's dictionary and QuartzCore's IOMFBColorMatrix)
    return m.astype(np.float32).astype(np.float64)


def tint_matrix(hue, intensity):
    """The Color Tint filter's matrix, made the way MADisplayFilterCopySystemFilter makes it when Color
    Tint is on: MADisplayFilterCreateSingleColor(hue, _, _, intensity). Each row gives one channel of
    the result from the red, green and blue that go in. Its post offsets are dropped on the way to the
    DCP (SkyLight passes only the matrix), and they're zero anyway."""
    return _filter_matrix(_ma.MADisplayFilterCreateSingleColor(hue, 0, 0, intensity))


def grayscale_matrix(intensity=1.0):
    """The Grayscale filter's matrix, MADisplayFilterCreateGrayscale(intensity, ...), for check.py."""
    return _filter_matrix(_ma.MADisplayFilterCreateGrayscale(intensity, 0, 0, 1))


# --- Colour profiles ------------------------------------------------------------------------------

class Profile:
    """An RGB matrix/TRC ICC profile, as displays and Display P3 and sRGB have: its tone curves and its
    primaries (adapted to the D50 of the PCS, so white goes to white)."""

    def __init__(self, data):
        self.data = bytes(data)
        count = struct.unpack(">I", self.data[128:132])[0]
        self.tags = {}
        for i in range(count):
            sig, off, size = struct.unpack(">4sII", self.data[132 + 12 * i:144 + 12 * i])
            self.tags[sig.decode("latin-1")] = (off, size)
        self.to_xyz = np.array([self._xyz(t) for t in ("rXYZ", "gXYZ", "bXYZ")]).T
        self.curves = [self._curve(t) for t in ("rTRC", "gTRC", "bTRC")]

    def _xyz(self, tag):
        off, _ = self.tags[tag]
        return [v / 65536 for v in struct.unpack(">3i", self.data[off + 8:off + 20])]

    def _curve(self, tag):
        off, _ = self.tags[tag]
        kind = self.data[off:off + 4]
        if kind == b"curv":
            count = struct.unpack(">I", self.data[off + 8:off + 12])[0]
            values = np.array(struct.unpack(">%dH" % count, self.data[off + 12:off + 12 + 2 * count])) / 65535
            if count == 1:
                return ("gamma", values[0] * 65535 / 256)
            return ("table", values)
        if kind == b"para":
            function = struct.unpack(">H", self.data[off + 8:off + 10])[0]
            n = {0: 1, 1: 3, 2: 4, 3: 5, 4: 7}[function]
            p = [v / 65536 for v in struct.unpack(">%di" % n, self.data[off + 12:off + 12 + 4 * n])]
            return ("para", function, p)
        raise ValueError(f"tone curve {kind!r}")

    @staticmethod
    def _para_decode(function, p, x):
        g = p[0]
        if function == 0:
            return x ** g
        a, b = p[1], p[2]
        if function == 1:
            return np.where(x >= -b / a, np.maximum(a * x + b, 0) ** g, 0)
        if function == 2:
            return np.where(x >= -b / a, np.maximum(a * x + b, 0) ** g + p[3], p[3])
        c, d = p[3], p[4]
        e, f = (p[5], p[6]) if function == 4 else (0, 0)
        return np.where(x >= d, np.maximum(a * x + b, 0) ** g + e, c * x + f)

    def decode(self, rgb):
        """Encoded values, 0...1, to light."""
        out = np.empty_like(rgb, dtype=np.float64)
        for ch, curve in enumerate(self.curves):
            x = np.clip(rgb[..., ch], 0, 1)
            if curve[0] == "table":
                table = curve[1]
                out[..., ch] = np.interp(x, np.linspace(0, 1, len(table)), table)
            elif curve[0] == "gamma":
                out[..., ch] = x ** curve[1]
            else:
                out[..., ch] = self._para_decode(curve[1], curve[2], x)
        return out

    def encode(self, light):
        """Light, 0...1, to encoded values: each curve inverted through a fine table of it."""
        x = np.linspace(0, 1, 65537)
        out = np.empty_like(light, dtype=np.float64)
        for ch in range(3):
            y = self.decode(np.repeat(x[:, None], 3, axis=1))[:, ch]
            out[..., ch] = np.interp(np.clip(light[..., ch], 0, 1), y, x)
        return out


def _colorspace_profile(colorspace):
    return Profile(Quartz.CGColorSpaceCopyICCData(colorspace))


def named_profile(name):
    """macOS's own profile for a named colour space, such as Quartz.kCGColorSpaceDisplayP3."""
    return _colorspace_profile(Quartz.CGColorSpaceCreateWithName(name))


VIDEO_SPACES = {"display-p3": Quartz.kCGColorSpaceDisplayP3, "srgb": Quartz.kCGColorSpaceSRGB}


# --- Displays -------------------------------------------------------------------------------------

BACKLIGHT, GAMMA, SIDECAR = "backlight", "gamma", "sidecar"

_ds = ctypes.CDLL("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
_ds.DisplayServicesCanChangeBrightness.restype = ctypes.c_bool
_ds.DisplayServicesCanChangeBrightness.argtypes = [ctypes.c_uint32]
_cd = ctypes.CDLL("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")
_cd.CoreDisplay_DisplayCreateInfoDictionary.restype = ctypes.c_void_p
_cd.CoreDisplay_DisplayCreateInfoDictionary.argtypes = [ctypes.c_uint32]


@dataclass
class Display:
    name: str
    kind: str                 # BACKLIGHT: the Mac sets its brightness; GAMMA: dimmed with the gamma table; SIDECAR: sent its picture
    profile: Profile          # the colour space its frames are drawn in
    min_light: float = 0.0    # BACKLIGHT: the least its white can give off, as a share of the most

    @classmethod
    def live(cls, display_id=None):
        """A connected display as macOS sees it now, the main one if no ID is given. Its kind is told as
        GammaManager tells it."""
        display_id = Quartz.CGMainDisplayID() if display_id is None else display_id
        profile = _colorspace_profile(Quartz.CGDisplayCopyColorSpace(display_id))
        info = _cd.CoreDisplay_DisplayCreateInfoDictionary(display_id)
        info = objc.objc_object(c_void_p=info) if info else {}
        names = info.get("DisplayProductName", {}) if info else {}
        name = names.get("en_US") or next(iter(names.values()), None) or f"Display {display_id}"
        if info.get("kCGDisplayIsVirtualDevice", False):
            return cls(name, SIDECAR, profile)
        if _ds.DisplayServicesCanChangeBrightness(display_id):
            low, high, _ = hid_brightness(name)
            return cls(name, BACKLIGHT, profile, low / high)
        return cls(name, GAMMA, profile)


def hid_brightness(product):
    """An Apple display's HID brightness (usage page 0x82, usage 0x10), which CoreBrightness scales the
    slider to: its logical range (400...60000 hundredths of a nit for a Studio Display) and the value it
    reports now."""
    iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    c = ctypes.c_void_p
    for fn, res, args in [("IOHIDManagerCreate", c, [c, ctypes.c_uint32]), ("IOHIDManagerSetDeviceMatching", None, [c, c]),
                          ("IOHIDManagerCopyDevices", c, [c]), ("IOHIDDeviceGetProperty", c, [c, c]),
                          ("IOHIDDeviceOpen", ctypes.c_int, [c, ctypes.c_uint32]), ("IOHIDDeviceClose", ctypes.c_int, [c, ctypes.c_uint32]),
                          ("IOHIDDeviceCopyMatchingElements", c, [c, c, ctypes.c_uint32]),
                          ("IOHIDDeviceGetValue", ctypes.c_int, [c, c, ctypes.POINTER(c)]), ("IOHIDValueGetIntegerValue", ctypes.c_long, [c]),
                          ("IOHIDElementGetType", ctypes.c_int, [c]),
                          ("IOHIDElementGetUsagePage", ctypes.c_uint32, [c]), ("IOHIDElementGetUsage", ctypes.c_uint32, [c]),
                          ("IOHIDElementGetLogicalMin", ctypes.c_long, [c]), ("IOHIDElementGetLogicalMax", ctypes.c_long, [c])]:
        getattr(iokit, fn).restype, getattr(iokit, fn).argtypes = res, args
    cf = lambda value: objc.pyobjc_id(Foundation.NSDictionary.dictionaryWithDictionary_(value) if isinstance(value, dict)
                                      else Foundation.NSString.stringWithString_(value).nsstring())
    manager = iokit.IOHIDManagerCreate(None, 0)
    iokit.IOHIDManagerSetDeviceMatching(manager, cf({"VendorID": 0x05AC}))
    devices = iokit.IOHIDManagerCopyDevices(manager)
    for device in (objc.objc_object(c_void_p=devices) if devices else []):
        ref = objc.pyobjc_id(device)
        if str(objc.objc_object(c_void_p=iokit.IOHIDDeviceGetProperty(ref, cf("Product")))) != product:
            continue
        for element in objc.objc_object(c_void_p=iokit.IOHIDDeviceCopyMatchingElements(ref, None, 0)):
            e = objc.pyobjc_id(element)
            if (iokit.IOHIDElementGetUsagePage(e), iokit.IOHIDElementGetUsage(e)) != (0x82, 0x10) or iokit.IOHIDElementGetType(e) != 257:
                continue  # 257: the feature report, which holds the brightness the display is at
            value, now = c(), None
            if iokit.IOHIDDeviceOpen(ref, 0) == 0:
                if iokit.IOHIDDeviceGetValue(ref, e, ctypes.byref(value)) == 0:
                    now = iokit.IOHIDValueGetIntegerValue(value)
                iokit.IOHIDDeviceClose(ref, 0)
            return iokit.IOHIDElementGetLogicalMin(e), iokit.IOHIDElementGetLogicalMax(e), now
    raise LookupError(f"no HID brightness for {product}")


# --- What the display shows -----------------------------------------------------------------------

def gamma_table(brightness, size=256):
    """GammaManager.calculateGammaTable: the table Safelight sets to dim a display in software."""
    return np.arange(size, dtype=np.float32) / np.float32(size - 1) * np.float32(brightness)


def dark_layer(frame, brightness):
    """Sidecar's dark layer over `frame` (encoded values, 0...1), as WindowServer draws it: DimmingWindow
    is black at an alpha of 1 − brightness, worked out in Float as GammaManager does and kept to 8 bits,
    and it's blended in half floats. Bit for bit what a screen capture shows (check.py dark-layer)."""
    alpha = np.float32(1) - np.float32(max(brightness, 0.1))
    alpha8 = np.floor(np.float32(alpha * np.float32(255)) + np.float32(0.5))
    through = np.float16(1) - np.float16(alpha8 / 255)
    return (np.asarray(frame).astype(np.float16) * through).astype(np.float64)


def shown(frame, display, tint=None, brightness=1.0, domain=None):
    """The light `display` gives off for `frame`, its encoded values (0...1, in the display's colour
    space, Sidecar's dark layer not yet in it), with Color Tint at `tint` (hue, intensity) or off, and
    at Safelight's `brightness` for that display. Linear, in the display's primaries, 1 = its white at
    full brightness."""
    domain = domain or MATRIX_DOMAIN
    x = np.asarray(frame, np.float64)[..., :3]
    if display.kind == SIDECAR:
        # Nothing reaches the iPad after the dark layer
        return display.profile.decode(dark_layer(x, brightness) if brightness < 0.999 else x)
    if display.kind == GAMMA and brightness < 0.999:
        table = gamma_table(max(brightness, 0.05))
        x = np.interp(x, np.linspace(0, 1, len(table)), table)
    if tint is not None and domain == "encoded":
        x = x @ tint_matrix(*tint).T
    light = display.profile.decode(x)
    if tint is not None and domain == "linear":
        light = light @ tint_matrix(*tint).T
    if display.kind == BACKLIGHT:
        light = light * max(brightness, display.min_light)
    return light


def to_video(light, display, space="display-p3", bits=8):
    """`light` from shown() as a video frame's values in `space` (display-p3 or srgb), the way ColorSync
    matches colours with these profiles: the display's primaries to the PCS, to the video's, both D50
    adapted so the display's white is the video's white. Whatever is outside the video's colours is
    clipped."""
    video = named_profile(VIDEO_SPACES[space])
    rgb = light @ (np.linalg.inv(video.to_xyz) @ display.profile.to_xyz).T
    encoded = video.encode(np.clip(rgb, 0, 1))
    scale = (1 << bits) - 1
    return np.round(encoded * scale).astype(np.uint16 if bits > 8 else np.uint8)


# --- Pictures -------------------------------------------------------------------------------------

def load(path, display):
    """A picture's encoded values in `display`'s colour space, 0...1. One in another colour space is
    matched to the display's by CoreGraphics, as WindowServer would."""
    image = Image.open(path)
    icc = image.info.get("icc_profile")
    rgb = np.asarray(image.convert("RGB"), np.float64) / 255
    if icc and Profile(icc).data != display.profile.data:
        rgb = cg_convert(rgb, icc, display.profile.data)
    return rgb


def cg_convert(rgb, src_icc, dst_icc):
    """Encoded values from one ICC profile's colour space to another's, by CoreGraphics (ColorSync)."""
    h, w = rgb.shape[:2]
    src = Quartz.CGColorSpaceCreateWithICCData(src_icc)
    dst = Quartz.CGColorSpaceCreateWithICCData(dst_icc)
    pixels = np.ascontiguousarray(np.dstack([rgb, np.ones((h, w))]).astype(np.float32))
    provider = Quartz.CGDataProviderCreateWithData(None, pixels.tobytes(), pixels.nbytes, None)
    info = Quartz.kCGImageAlphaPremultipliedLast | Quartz.kCGBitmapFloatComponents | Quartz.kCGBitmapByteOrder32Little
    image = Quartz.CGImageCreate(w, h, 32, 128, w * 16, src, info, provider, None, False, Quartz.kCGRenderingIntentDefault)
    context = Quartz.CGBitmapContextCreate(None, w, h, 32, w * 16, dst, info)
    Quartz.CGContextSetBlendMode(context, Quartz.kCGBlendModeCopy)
    Quartz.CGContextDrawImage(context, Quartz.CGRectMake(0, 0, w, h), image)
    data = Quartz.CGBitmapContextGetData(context)
    out = np.frombuffer(data.as_buffer(h * w * 16), np.float32).reshape(h, w, 4)
    return out[..., :3].astype(np.float64)


def save(path, values, space="display-p3", bits=8):
    """A frame from to_video() as a PNG tagged with the video's colour space."""
    icc = bytes(Quartz.CGColorSpaceCopyICCData(Quartz.CGColorSpaceCreateWithName(VIDEO_SPACES[space])))
    if bits > 8:
        # Pillow can't write 16-bit RGB, so the 16-bit PNG goes through ImageIO
        h, w = values.shape[:2]
        data = (values.astype(np.uint32) * 65535 // ((1 << bits) - 1)).astype(">u2").tobytes()
        provider = Quartz.CGDataProviderCreateWithData(None, data, len(data), None)
        cs = Quartz.CGColorSpaceCreateWithICCData(icc)
        image = Quartz.CGImageCreate(w, h, 16, 48, w * 6, cs, Quartz.kCGImageAlphaNone | Quartz.kCGBitmapByteOrder16Big,
                                     provider, None, False, Quartz.kCGRenderingIntentDefault)
        url = Quartz.CFURLCreateWithFileSystemPath(None, path, Quartz.kCFURLPOSIXPathStyle, False)
        dest = Quartz.CGImageDestinationCreateWithURL(url, "public.png", 1, None)
        Quartz.CGImageDestinationAddImage(dest, image, None)
        Quartz.CGImageDestinationFinalize(dest)
    else:
        Image.fromarray(values.astype(np.uint8), "RGB").save(path, icc_profile=icc)


def main():
    parser = argparse.ArgumentParser(description="What a display shows of a frame with Safelight's settings.")
    parser.add_argument("frame")
    parser.add_argument("out")
    parser.add_argument("--display", type=int)
    parser.add_argument("--tint", help="hue,intensity")
    parser.add_argument("--brightness", type=float, default=1.0)
    parser.add_argument("--space", choices=VIDEO_SPACES, default="display-p3")
    parser.add_argument("--bits", type=int, default=8)
    args = parser.parse_args()
    display = Display.live(args.display)
    tint = tuple(float(v) for v in args.tint.split(",")) if args.tint else None
    light = shown(load(args.frame, display), display, tint, args.brightness)
    save(args.out, to_video(light, display, args.space, args.bits), args.space, args.bits)


if __name__ == "__main__":
    main()
