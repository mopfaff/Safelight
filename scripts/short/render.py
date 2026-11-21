#!/usr/bin/env python3
# Makes the short, 1080×1920 at 30 frames a second, from the README's screenshots and the pictures
# Assets.swift writes. Run it with scripts/make-short.sh, which writes those first. reveal.py makes
# the short's second version with the parts here.
#
#   render.py            writes build/short/safelight-short.mp4
#   render.py 1 6.5      writes build/short/still-1.0.png and still-6.5.png, the frames at those seconds
#
# A screen recording never shows the color filter or brightness, which macOS applies after the screen
# is drawn, so they're applied to the screenshots here, the way the Schedule's day strip shows them:
# white comes out as hue tint, saturation intensity, brightness brightness.
import io, os, subprocess, sys
import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
OUT = os.path.join(REPO, "build", "short")
ASSETS = os.path.join(OUT, "assets")
W, H, FPS = 1080, 1920, 30
FONT = "/System/Library/Fonts/SFNS.ttf"
SRGB = ImageCms.createProfile("sRGB")

# Timeline, in seconds
A_END, B_END, END = 4.2, 11.2, 14.8
FADE_IN, FADE_TIME = 1.0, 1.2           # shot A: the filter coming on
XFADE = 0.3
# Shot B's clock, (second, minute): quick through the afternoon, slow from just before 18:00 to just
# after 18:30, while the filter fades in and the Mac goes Dark, then on to 22:00
CLOCK = [(A_END, 16 * 60), (5.8, 17 * 60 + 55), (7.6, 18 * 60 + 32), (11.2, 22 * 60)]

# Captions: from, to (seconds), lines, centre y. Kept clear of the bottom fifth, where Shorts and
# TikTok put the title and channel, and of the buttons down the right.
CAPTIONS = [
    (0.15, 2.5, ["Night Shift can’t do this"], 1500),
    (2.5, A_END, ["Safelight goes full red"], 1500),
    (A_END + 0.1, 5.8, ["White by day…"], 1330),
    (5.8, 7.5, ["…red by night"], 1330),
    (7.5, B_END, ["Dark Mode and wallpaper", "switch with it"], 1330),
]


def minute_at(t):
    return float(np.interp(t, *zip(*CLOCK)))


def srgb(path, size=None):
    image = Image.open(path)
    icc = image.info.get("icc_profile")
    image = image.convert("RGBA")
    if size:
        image = image.resize(size, Image.LANCZOS)
    if icc:
        image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(icc)), SRGB, outputMode="RGBA")
    return image


def scaled(image, scale):
    size = (round(image.width * scale), round(image.height * scale))
    return image.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def arr(image):
    return np.asarray(image, dtype=np.float32) / 255


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def over(dst, src, x, y, opacity=1.0):
    """Puts the straight-alpha RGBA array `src` over the RGB array `dst` with its top left at x, y."""
    h, w = src.shape[:2]
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, dst.shape[1]), min(y + h, dst.shape[0])
    if x0 >= x1 or y0 >= y1:
        return
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    a = s[..., 3:4] * opacity
    dst[y0:y1, x0:x1] = dst[y0:y1, x0:x1] * (1 - a) + s[..., :3] * a


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


# The default schedule when the Short was made, which it still shows: minute, filter on, intensity, brightness, Dark (all with tint 0, red)
SCHEDULE = [(330, True, 0.90, 0.82, True), (360, False, 0.25, 1.00, False), (1080, False, 0.25, 1.00, False),
            (1110, True, 0.80, 0.92, True), (1230, True, 0.90, 0.68, True)]


def settings(minute):
    """ColorKeyframe.settings(in:at:) for that schedule: (intensity, brightness, isDark)."""
    before = [i for i, k in enumerate(SCHEDULE) if k[0] <= minute]
    i = before[-1] if before else -1
    start, end = SCHEDULE[i], SCHEDULE[(i + 1) % len(SCHEDULE)]
    start_minute = start[0] - (1440 if not before else 0)
    end_minute = end[0] + (1440 if end[0] <= start_minute else 0)
    p = (minute - start_minute) / (end_minute - start_minute)
    si, ei = (start[2] if start[1] else 0), (end[2] if end[1] else 0)
    return si + (ei - si) * p, start[3] + (end[3] - start[3]) * p, start[4]


LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)


def color_filter(rgb, intensity, brightness):
    """A red Color Tint filter at `intensity`, and the display at `brightness`: white comes out as
    the day strip's colour, HSB(0, intensity, brightness)."""
    out = rgb
    if intensity > 0:
        y = rgb @ LUMA
        out = rgb * (1 - intensity)
        out[..., 0] += y * intensity
    if brightness < 1:
        out = out * brightness
    return out


# --- Assets -------------------------------------------------------------------------------------

def wallpaper(name):
    # The square picture, as high as the frame, the hills and their sky at the middle
    image = srgb(os.path.join(ASSETS, f"wallpaper-{name}.png"), (H, H)).convert("RGB")
    left = (H - W) // 2
    return arr(image.crop((left, 0, left + W, H)))


WALL = {False: wallpaper("light"), True: wallpaper("dark")}

# Shot A: the popover open under its icon, its menu bar along the top of the screen
POPOVER_SCALE = 1.1
popover = scaled(srgb(os.path.join(REPO, "docs/popover-light.png")), POPOVER_SCALE)
POPOVER_AT = (W - 18 - popover.width, 14)
SCREEN_A = WALL[False].copy()
over(SCREEN_A, arr(popover), *POPOVER_AT)
SCREEN_A_IMAGE = Image.fromarray((SCREEN_A * 255 + 0.5).astype(np.uint8))


def schedule_window(dark):
    """The Schedule window without its line at the current time (21:00 in the screenshot), so one can
    be drawn wherever the clock is; and where its day strip is."""
    image = srgb(os.path.join(REPO, f"docs/schedule-{'dark' if dark else 'light'}.png"))
    a = arr(image).copy()
    # The accent-coloured line: blue among the strip's reds and whites, above the rows' blue
    # Appearance pictures
    blue = (a[:400, :, 2] - a[:400, :, 0] > 0.25) & (a[:400, :, 3] > 0.99)
    rows, cols = np.nonzero(blue)
    top, bottom = rows.min(), rows.max() + 1
    accent = a[rows[0], cols[len(cols) // 2], :3].copy()
    left, right = cols.min() - 1, cols.max() + 2
    for c in range(left, right):
        k = (c - left + 1) / (right - left + 1)
        a[top:bottom, c] = a[top:bottom, left - 1] * (1 - k) + a[top:bottom, right] * k
    # The strip's ends, both red at midnight
    row = a[(top + bottom) // 2]
    red = np.nonzero((row[:, 0] - row[:, 1] > 0.3) & (row[:, 3] > 0.99))[0]
    strip_left, strip_right = red.min(), red.max() + 1
    return a, (top, bottom, strip_left, strip_right), accent


SCHEDULE_SCALE = 0.52
SCHEDULE_Y = 640
_schedule = {d: schedule_window(d) for d in (False, True)}
SCHEDULE_IMG = {}
for d, (a, _, _) in _schedule.items():
    image = Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGBA")
    SCHEDULE_IMG[d] = arr(scaled(image, SCHEDULE_SCALE))
_, STRIP, ACCENT = _schedule[True]
SCHEDULE_X = (W - SCHEDULE_IMG[False].shape[1]) // 2


def screen_b(minute, t_switch, t):
    """The Schedule over the desktop at `minute`, Dark fading in from `t_switch` seconds."""
    ui = smooth((t - t_switch) / 0.35) if t_switch is not None else 0
    wall = smooth((t - t_switch) / 1.6) if t_switch is not None else 0
    rgb = WALL[False] * (1 - wall) + WALL[True] * wall if 0 < wall < 1 else WALL[wall >= 1].copy()
    if 0 < ui < 1:
        over(rgb, SCHEDULE_IMG[False], SCHEDULE_X, SCHEDULE_Y)
        over(rgb, SCHEDULE_IMG[True], SCHEDULE_X, SCHEDULE_Y, ui)
    else:
        over(rgb, SCHEDULE_IMG[ui >= 1], SCHEDULE_X, SCHEDULE_Y)
    # The line at the current time, 2 points wide, across the strip
    top, bottom, left, right = STRIP
    x = SCHEDULE_X + (left + (right - left) * minute / 1440) * SCHEDULE_SCALE
    half = 2 * SCHEDULE_SCALE  # 1 point either side, at 2 pixels a point
    y0, y1 = SCHEDULE_Y + round(top * SCHEDULE_SCALE), SCHEDULE_Y + round(bottom * SCHEDULE_SCALE)
    for c in range(int(x - half) - 1, int(x + half) + 2):
        cover = max(0.0, min(c + 1, x + half) - max(c, x - half))
        if cover > 0:
            rgb[y0:y1, c] = rgb[y0:y1, c] * (1 - cover) + ACCENT * cover
    return rgb


# --- Text ---------------------------------------------------------------------------------------

def pill(lines, size=64, weight="Heavy", pad=(38, 24), gap=10, fill=(0, 0, 0, 165)):
    f = font(size, weight)
    boxes = [f.getbbox(line) for line in lines]
    width = max(b[2] - b[0] for b in boxes) + 2 * pad[0]
    line_h = round(size * 1.12)
    height = line_h * len(lines) + gap * (len(lines) - 1) + 2 * pad[1]
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, width - 1, height - 1), radius=min(height // 2, 44), fill=fill)
    for i, (line, box) in enumerate(zip(lines, boxes)):
        y = pad[1] + i * (line_h + gap) + (line_h - size) // 2 - round(size * 0.06)
        draw.text(((width - (box[2] - box[0])) / 2 - box[0], y), line, font=f, fill=(255, 255, 255))
    return arr(image)


CAPTION_ART = [pill(lines) for _, _, lines, _ in CAPTIONS]


def captions(rgb, t):
    for (start, end, _, cy), art in zip(CAPTIONS, CAPTION_ART):
        if start <= t < end:
            appear = smooth((t - start) / 0.18)
            leave = smooth((end - t) / 0.12) if end < END - 1 else 1
            rise = round((1 - appear) * 18)
            over(rgb, art, (W - art.shape[1]) // 2, cy - art.shape[0] // 2 + rise, appear * leave)


CLOCK_FONT = font(170, "Bold")
DIGIT_W = max(CLOCK_FONT.getbbox(d)[2] - CLOCK_FONT.getbbox(d)[0] for d in "0123456789") + 6


def clock(minute):
    """The time in big digits, each in a cell of its own width so they don't shuffle about."""
    text = f"{int(minute // 60):02d}:{int(minute % 60):02d}"
    colon_w = 54
    width = DIGIT_W * 4 + colon_w + 2 * 48
    height = 230
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, width - 1, height - 1), radius=44, fill=(0, 0, 0, 150))
    x = 48
    for ch in text:
        cell = colon_w if ch == ":" else DIGIT_W
        box = CLOCK_FONT.getbbox(ch)
        draw.text((x + (cell - (box[2] - box[0])) / 2 - box[0], 6), ch, font=CLOCK_FONT, fill=(255, 255, 255))
        x += cell
    return arr(image)


# --- End card -----------------------------------------------------------------------------------

def end_card():
    background, glow = np.array([20, 19, 30], np.float32) / 255, np.array([150, 28, 16], np.float32) / 255
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.sqrt(((xx - W / 2) / 620) ** 2 + ((yy - 760) / 620) ** 2)
    g = np.clip(1 - d, 0, 1) ** 2 * 0.6
    rgb = background * (1 - g[..., None]) + glow * g[..., None]
    icon = scaled(srgb(os.path.join(ASSETS, "icon.png")), 400 / 1024)
    over(rgb, arr(icon), (W - icon.width) // 2, 520)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    def centred(y, text, f, fill):
        box = f.getbbox(text)
        draw.text(((W - (box[2] - box[0])) / 2 - box[0], y), text, font=f, fill=fill)

    centred(960, "Safelight", font(132, "Bold"), (255, 255, 255))
    centred(1130, "White by day, red by night.", font(52, "Medium"), (226, 222, 232))
    centred(1290, "Free and open source, for Mac", font(42, "Regular"), (176, 172, 190))
    centred(1350, "github.com/mopfaff/Safelight", font(42, "Semibold"), (240, 236, 244))
    over(rgb, arr(layer), 0, 0)
    return rgb


END_CARD = end_card()

# --- Frames -------------------------------------------------------------------------------------

B_SWITCH = None  # when the clock passes 18:30 and the Mac goes Dark
for n in range(int(A_END * FPS), int(B_END * FPS)):
    t = n / FPS
    if settings(minute_at(t))[2]:
        B_SWITCH = t
        break


def shot_a(t):
    # A slow push in from the menu bar's corner, so the clock stays on screen
    z = 1 + 0.06 * smooth(t / A_END)
    w, h = W / z, H / z
    x0, y0 = W - w, 0
    rgb = arr(SCREEN_A_IMAGE.resize((W, H), Image.BICUBIC, box=(x0, y0, x0 + w, y0 + h)))
    k = smooth((t - FADE_IN) / FADE_TIME)
    return color_filter(rgb, 0.90 * k, 1 - 0.32 * k)  # to the popover's own intensity and brightness


def shot_b(t):
    minute = minute_at(t)
    intensity, brightness, _ = settings(minute)
    rgb = color_filter(screen_b(minute, B_SWITCH if B_SWITCH is not None and t >= B_SWITCH else None, t), intensity, brightness)
    art = clock(minute)
    over(rgb, art, (W - art.shape[1]) // 2, 300)
    return rgb


def frame(t):
    if t < A_END:
        rgb = shot_a(t)
        captions(rgb, t)
    elif t < B_END:
        rgb = shot_b(t)
        captions(rgb, t)
        if t < A_END + XFADE:  # from the last of shot A
            k = smooth((t - A_END) / XFADE)
            last = shot_a(A_END - 1 / FPS)
            captions(last, A_END - 1 / FPS)
            rgb = last * (1 - k) + rgb * k
    else:
        rgb = END_CARD.copy()
        if t < B_END + XFADE:
            k = smooth((t - B_END) / XFADE)
            last = shot_b(B_END - 1 / FPS)
            captions(last, B_END - 1 / FPS)
            rgb = last * (1 - k) + rgb * k
    return (np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)


def write(frame, end, video, still):
    """Writes build/short/<video>.mp4 from `frame`, the picture at a time in seconds, `end` seconds
    long; or with seconds given on the command line, the frames at those seconds, <still>-<seconds>.png."""
    if len(sys.argv) > 1:
        for seconds in map(float, sys.argv[1:]):
            path = os.path.join(OUT, f"{still}-{seconds:.1f}.png")
            Image.fromarray(frame(seconds)).save(path)
            print(f"Wrote {os.path.relpath(path, REPO)}")
        return
    out = os.path.join(OUT, f"{video}.mp4")
    # H.264 in BT.709, which every site and phone plays as it should, with a silent soundtrack, as some
    # editors won't add music to a video with none
    ffmpeg = subprocess.Popen([
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
        "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-profile:v", "high",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out], stdin=subprocess.PIPE)
    frames = round(end * FPS)
    for n in range(frames):
        ffmpeg.stdin.write(frame(n / FPS).tobytes())
    ffmpeg.stdin.close()
    if ffmpeg.wait():
        sys.exit("ffmpeg couldn't write the video")
    print(f"Wrote {os.path.relpath(out, REPO)}")


if __name__ == "__main__":
    write(frame, END, "safelight-short", "still")
