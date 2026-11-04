#!/usr/bin/env python3
# Cuts Safelight's demo videos from the finished demo shots (scripts/make-demo.sh <scene>), as each edit
# file in scripts/demo/edits/ has it: which shots, from when to when in each, the captions over them and an
# end card, and the platform the video is for, which sets its colours and how it's encoded. Run it with
# scripts/make-demo.sh --edit, which draws Safelight's icon for the end card first.
#
#   edit.py [<edit>...]          writes build/demo/edits/<edit>/safelight-<edit>.mp4 for each edit named, or
#                                for all of them, with stills/ (frames of it as PNGs: a little way in, the
#                                middle of each caption, the end card) and sheet.png (all of them, small)
#   edit.py verify [<edit>...]   decodes the videos as macOS's players do (AVFoundation), in each video's own
#                                colours, and compares them with the frames they were made from
#
# Only editorial things happen here: cuts between shots, captions, the end card faded in over the last shot.
# Nothing changes what a screen shows inside a shot. Each shot's master (its <scene>-<camera>.mp4, Display
# P3, HEVC, 10 bits) is decoded here as it was encoded (compose.ycbcr: BT.709's luma and chroma at video's
# limited range, chroma at the left of its two columns), so the values are the master's own; a 16:9 master,
# 3840×2160, is halved to 1920×1080 by averaging each 2×2 pixels' light, as compose.py's camera scales.
#
# Each platform's colours, as found on 4 November 2026, not assumed:
#   youtube  YouTube's upload settings (support.google.com/youtube/answer/1722171) want SDR in BT.709 and
#            convert anything else themselves; a wide gamut only comes as HDR (BT.2020 with PQ or HLG). So the
#            P3 values are matched to sRGB's primaries here, the deepest reds clipped as compose.py's -srgb
#            copies are, and tagged BT.709 all through. Their curve is sRGB's: Chromium shows BT.709's tone
#            curve and sRGB's alike (a grey of 128 drawn as 128 either way, tried with tagged videos), and
#            tagged with sRGB's curve, YouTube would re-encode them to BT.709's, which Chromium then shows
#            darker. 60 fps H.264 as YouTube asks: High profile, a closed GOP of half the frame rate, 2 B-frames
#            in a row, no edit lists, the index at the front, and a silent sound track to add music to.
#   x        X's media guide (docs.x.com/x-api/media/quickstart/best-practices) says nothing about colour: it
#            gets the same as YouTube. H.264 High, 4:2:0, no open GOP, 60 fps, with a silent AAC track.
#   github   A README's video is the file itself, played by the browser, at most 10 MB on a free plan
#            (docs.github.com, attaching files). Chromium shows Display P3 tags as they are (tried with H.264
#            and HEVC: P3's red came out as P3's red) and Safari decodes with AVFoundation, which
#            compose.py verify shows decoding the P3 masters right, so it keeps the masters' P3, in H.264 for
#            browsers without HEVC, in two passes at the bit rate that fits under maxBytes, with no sound.
#            Firefox wasn't tried.
#
# An edit file (scripts/demo/edits/<edit>.json):
#   "base"       another edit whose keys this one starts from (its own replace them)
#   "platform"   youtube, x or github; "camera" the shots' camera, 9:16 or 16:9; "size" of the video in
#                pixels (the master's, or half of it); "fps" (60, or 30 taking every other frame)
#   "caption"    how captions look: "size" of the text in pixels, "y" where the middle of a caption sits (a
#                fraction of the height), "maxWidth" in pixels, which none may be wider than
#   "clips"      in order, each {"shot", "from", "to"}, in seconds of the shot, and its "captions": each
#                {"from", "to", in seconds of the shot, "text" (a line, or a list of them), "small" (a smaller
#                line under it), "x" and "y" (where its middle sits, fractions of the width and height; the
#                middle across, and the edit's "y", unless given)}. A caption fades in, unless it's there as
#                the clip starts, and out, unless it lasts until the clip is cut
#   "endCard"    {"duration", "fade" (over the end of the last clip), "lines"}: Safelight's icon over black,
#                with its name and the lines under it, or null for none
#
# Re-running gives the same files, byte for byte. Needs what compose.py needs.
import argparse, collections, copy, json, multiprocessing, shutil, subprocess, sys
from pathlib import Path
import numpy as np
import Quartz
from PIL import Image, ImageDraw, ImageFont
import pipeline
from compose import Foundation_url, pixel_buffer, report, ycbcr

ROOT = Path(__file__).resolve().parents[2]
EDITS = ROOT / "scripts" / "demo" / "edits"
SCENES = ROOT / "scripts" / "demo" / "scenes"
BUILD = ROOT / "build" / "demo"
OUT = BUILD / "edits"
ICON = OUT / "icon" / "icon.png"
FONT = "/System/Library/Fonts/SFNS.ttf"

PLATFORMS = {
    "youtube": {"space": "srgb", "primaries": "bt709", "transfer": "bt709", "audio": True, "crf": 14,
                "x264": "keyint={half}:min-keyint={half}:bframes=2:b-adapt=0:open-gop=0"},
    "x": {"space": "srgb", "primaries": "bt709", "transfer": "bt709", "audio": True, "crf": 16,
          "x264": "keyint={fps}:open-gop=0"},
    "github": {"space": "display-p3", "primaries": "smpte432", "transfer": "iec61966-2-1", "audio": False,
               "maxBytes": 9_500_000, "x264": "keyint={fps}:open-gop=0"},
}


# --- Colours --------------------------------------------------------------------------------------

P3 = pipeline.named_profile(Quartz.kCGColorSpaceDisplayP3)
SRGB = pipeline.named_profile(Quartz.kCGColorSpaceSRGB)
# Light in P3's primaries to sRGB's, as pipeline.to_video matches them (both adapted to D50, white to white)
P3_TO_SRGB = (np.linalg.inv(SRGB.to_xyz) @ P3.to_xyz).astype(np.float32)
# Display P3's tone curve, IEC 61966-2-1's, as its profile has it; sRGB's profile has it as a table
# within 1.2e-5 of it
_G, _A, _B, _C, _D = P3.curves[0][2]
assert all(curve[:2] == ("para", 3) for curve in P3.curves)


def to_light(values):
    x = np.clip(values, 0, 1, dtype=np.float32)
    return np.where(x >= _D, (_A * x + _B) ** _G, _C * x).astype(np.float32)


def to_values(light):
    y = np.clip(light, 0, 1, dtype=np.float32)
    return np.where(y >= (_A * _D + _B) ** _G, (y ** (1 / _G) - _B) / _A, y / _C).astype(np.float32)


def in_space(values, space):
    """Display P3 values as values in `space`: the same, or matched to sRGB's primaries, clipped"""
    if space == "display-p3":
        return values
    return to_values(to_light(values) @ P3_TO_SRGB.T)


def rgb_from_ycbcr(raw, width, height):
    """A frame of a 10-bit 4:2:0 master as its encoded values, 0...1: compose.ycbcr undone, the chroma
    taken back to every pixel from where it sits, at the left of its two columns, between its two rows"""
    planes = np.frombuffer(raw, "<u2")
    n = width * height
    y = (planes[:n].reshape(height, width).astype(np.float32) / 4 - 16) / 219

    def chroma(plane):
        c = (plane.reshape(height // 2, width // 2).astype(np.float32) / 4 - 128) / 224
        above, below = np.vstack([c[:1], c[:-1]]), np.vstack([c[1:], c[-1:]])
        rows = np.empty((height, width // 2), np.float32)
        rows[0::2], rows[1::2] = 0.75 * c + 0.25 * above, 0.75 * c + 0.25 * below
        out = np.empty((height, width), np.float32)
        out[:, 0::2] = rows
        out[:, 1::2] = (rows + np.hstack([rows[:, 1:], rows[:, -1:]])) / 2
        return out

    cb, cr = chroma(planes[n:n + n // 4]), chroma(planes[n + n // 4:])
    r, b = y + 1.5748 * cr, y + 1.8556 * cb
    g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
    return np.clip(np.dstack([r, g, b]), 0, 1)


# --- The edit -------------------------------------------------------------------------------------

def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def load(name):
    spec = json.loads((EDITS / f"{name}.json").read_text())
    if "base" in spec:
        base = load(spec["base"])
        base.update({k: v for k, v in spec.items() if k != "base"})
        spec = base
    return copy.deepcopy(spec)


Entry = collections.namedtuple("Entry", "clip frame captions card")


class Edit:
    """An edit file, and what's on each of its video's frames: which shot's frame, which captions, how
    much of the end card"""

    def __init__(self, name):
        self.name = name
        self.spec = load(name)
        self.platform = PLATFORMS[self.spec["platform"]]
        self.size = tuple(self.spec["size"])
        self.fps = self.spec["fps"]
        self.folder = OUT / name
        self.path = self.folder / f"safelight-{name}.mp4"
        camera = self.spec["camera"]
        self.clips = []
        for clip in self.spec["clips"]:
            scene = json.loads((SCENES / f"{clip['shot']}.json").read_text())
            master = (BUILD / clip["shot"] / f"{clip['shot']}-{camera.replace(':', 'x')}.mp4")
            if not master.exists():
                raise SystemExit(f"There's no {master.relative_to(ROOT)}: make it with scripts/make-demo.sh {clip['shot']}")
            size = tuple(scene["camera"][camera]["size"])
            scale = size[0] // self.size[0]
            if size[0] != self.size[0] * scale or size[1] != self.size[1] * scale:
                raise SystemExit(f"{self.name}: {clip['shot']}'s {camera} is {size[0]}×{size[1]}, not {self.size[0]}×{self.size[1]} or a whole multiple of it")
            if scene["fps"] % self.fps or not 0 <= clip["from"] < clip["to"] <= scene["duration"]:
                raise SystemExit(f"{self.name}: {clip['shot']} is {scene['duration']} s at {scene['fps']} fps; can't cut {clip['from']}–{clip['to']} s at {self.fps} fps")
            self.clips.append(dict(clip, master=master, size=size, shot_fps=scene["fps"]))
        self.card = self.spec.get("endCard")
        self.plan = self._plan()
        self.duration = len(self.plan) / self.fps

    def _plan(self):
        plan = []
        self.captions = [caption for clip in self.clips for caption in clip.get("captions", [])]
        i = 0
        for c, clip in enumerate(self.clips):
            count = round((clip["to"] - clip["from"]) * self.fps)
            step = clip["shot_fps"] // self.fps
            first = round(clip["from"] * clip["shot_fps"])
            captions = list(enumerate(clip.get("captions", []), i))
            i += len(captions)
            for k in range(count):
                t = clip["from"] + k / self.fps
                on = []
                for n, caption in captions:
                    if not caption["from"] <= t + 1e-9 < caption["to"]:
                        continue
                    appear = smooth((t - caption["from"]) / 0.25) if caption["from"] > clip["from"] + 1e-9 else 1.0
                    leave = smooth((caption["to"] - t) / 0.2) if caption["to"] < clip["to"] - 1e-9 else 1.0
                    rise = round((1 - appear) * 0.012 * self.size[1])
                    on.append((n, appear * leave, rise))
                plan.append(Entry(c, first + k * step, on, 0.0))
        if self.card:
            fade = round(self.card["fade"] * self.fps)
            start = len(plan) - fade
            for j in range(fade):
                plan[start + j] = plan[start + j]._replace(card=smooth((j + 0.5) / fade))
            plan += [Entry(None, None, [], 1.0)] * (round(self.card["duration"] * self.fps) - fade)
        return plan

    def stills(self):
        """Frames to keep as stills: a little way in, the middle of each caption, the end card's middle"""
        frames = {min(round(0.5 * self.fps), len(self.plan) - 1)}
        shown = collections.defaultdict(list)
        for k, entry in enumerate(self.plan):
            for i, opacity, _ in entry.captions:
                shown[i].append(k)
        frames |= {ks[len(ks) // 2] for ks in shown.values()}
        if self.card:
            frames.add(len(self.plan) - round(self.card["duration"] * self.fps * 0.4))
        return sorted(frames)

    # The pictures over the shots, made once in each worker

    def prepare(self):
        style = self.spec["caption"]
        self.caption_art = []
        for caption in self.captions:
            art = caption_picture(caption.get("text"), caption.get("small"), style["size"])
            if art.shape[1] > style["maxWidth"]:
                raise SystemExit(f"{self.name}: the caption {caption['text']!r} is {art.shape[1]} pixels wide, more than its maxWidth, {style['maxWidth']}")
            x = round(caption.get("x", 0.5) * self.size[0] - art.shape[1] / 2)
            y = round(caption.get("y", style["y"]) * self.size[1] - art.shape[0] / 2)
            self.caption_art.append((art, x, y))
        self.card_values = end_card(self.size, self.card["lines"], self.platform["space"]) if self.card else None

    def picture(self, raw, size, entry):
        """The video's values (in its own colour space, 0...1) on a frame of the plan"""
        if raw is None:
            return self.card_values.copy()
        values = rgb_from_ycbcr(raw, *size)
        scale = size[0] // self.size[0]
        if scale > 1:
            light = to_light(values)
            light = light.reshape(self.size[1], scale, self.size[0], scale, 3).mean(axis=(1, 3))
            values = to_values(light)
        values = in_space(values, self.platform["space"])
        for i, opacity, rise in entry.captions:
            art, x, y = self.caption_art[i]
            over(values, art, x, y + rise, opacity)
        if entry.card:
            values = values * (1 - entry.card) + self.card_values * entry.card
        return values


def over(dst, src, x, y, opacity=1.0):
    """Puts the straight-alpha RGBA array `src` over the RGB array `dst`, its top left at x, y"""
    h, w = src.shape[:2]
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, dst.shape[1]), min(y + h, dst.shape[0])
    if x0 >= x1 or y0 >= y1:
        return
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    a = s[..., 3:4] * opacity
    dst[y0:y1, x0:x1] = dst[y0:y1, x0:x1] * (1 - a) + s[..., :3] * a


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def caption_picture(text, small, size, supersample=4):
    """A caption: its lines in SF Pro Semibold, white, and a smaller line under them, on a rounded dark
    pill, drawn at 4 times the size and scaled down, so the pill's edge is smooth"""
    lines = [text] if isinstance(text, str) else list(text)
    s = supersample
    big, little = font(size * s, "Semibold"), font(round(size * 0.62) * s, "Medium")
    line_h, small_h = round(size * 1.2) * s, round(size * 0.62 * 1.3) * s
    pad_x, pad_y = round(size * 0.6) * s, round(size * 0.34) * s
    widths = [big.getlength(line) for line in lines] + ([little.getlength(small)] if small else [])
    width = (int(max(widths)) // s + 1) * s + 2 * pad_x
    height = line_h * len(lines) + (small_h if small else 0) + 2 * pad_y
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, width - 1, height - 1), radius=min(height // 2, round(size * 0.7) * s), fill=(0, 0, 0, 158))
    for n, line in enumerate(lines):
        draw.text((width / 2, pad_y + line_h * (n + 0.5)), line, font=big, fill=(255, 255, 255, 255), anchor="mm")
    if small:
        draw.text((width / 2, pad_y + line_h * len(lines) + small_h * 0.45), small, font=little, fill=(222, 222, 228, 255), anchor="mm")
    image = image.convert("RGBa").resize((width // s, height // s), Image.BOX).convert("RGBA")
    return np.asarray(image, np.float32) / 255


def end_card(size, lines, space):
    """Safelight's icon over black, its name under it, then the lines, in the video's colour space"""
    width, height = size
    tall = height > width
    unit = width / 2160 if tall else height / 1080
    values = np.zeros((height, width, 3), np.float32)
    icon_size = round((720 if tall else 300) * unit)
    icon = Image.open(ICON).convert("RGBA").convert("RGBa").resize((icon_size, icon_size), Image.LANCZOS).convert("RGBA")
    icon = np.asarray(icon, np.float32) / 255
    icon[..., :3] = in_space(icon[..., :3], space)
    top = round(height * (0.2 if tall else 0.16))
    over(values, icon, (width - icon_size) // 2, top)
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    y = top + icon_size + round((170 if tall else 104) * unit)
    styles = [((200 if tall else 92), "Bold", (255, 255, 255)), ((100 if tall else 44), "Regular", (190, 190, 198)),
              ((100 if tall else 44), "Semibold", (255, 255, 255))]
    for n, line in enumerate(lines):
        px, weight, colour = styles[min(n, len(styles) - 1)]
        px = round(px * unit)
        draw.text((width / 2, y), line, font=font(px, weight), fill=colour + (255,), anchor="ms")
        y += round(px * (1.9 if n == 0 else 1.45))
    over(values, np.asarray(layer, np.float32) / 255, 0, 0)
    return values


# --- Making the video -----------------------------------------------------------------------------

class Master:
    """A shot's master, decoded by ffmpeg into its 10-bit planes as they were encoded, frame by frame"""

    def __init__(self, clip):
        self.width, self.height = clip["size"]
        self.bytes = self.width * self.height * 3
        self.process = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(clip["master"]),
                                         "-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-"],
                                        stdout=subprocess.PIPE)
        self.next = 0

    def frame(self, number):
        while True:
            raw = self.process.stdout.read(self.bytes)
            if len(raw) != self.bytes:
                raise SystemExit(f"A master ended before its frame {number}")
            self.next += 1
            if self.next - 1 == number:
                return raw

    def close(self):
        # Killed before its pipe is closed, so it doesn't complain of the pipe it's writing to closing
        self.process.kill()
        self.process.wait()
        self.process.stdout.close()


def frames(edit):
    """Each frame of the plan with what it's made from: (number, raw master frame or None, its size, entry)"""
    masters = {}
    for k, entry in enumerate(edit.plan):
        raw = None
        if entry.clip is not None:
            if entry.clip not in masters:
                for master in masters.values():
                    master.close()
                masters = {entry.clip: Master(edit.clips[entry.clip])}
            raw = masters[entry.clip].frame(entry.frame)
        yield k, raw, edit.clips[entry.clip]["size"] if entry.clip is not None else None, entry
    for master in masters.values():
        master.close()


_edit = None


def _open(name):
    global _edit
    _edit = Edit(name)
    _edit.prepare()


def _render(task):
    raw, size, entry, keep = task
    values = _edit.picture(raw, size, entry)
    return ycbcr(values, 8), (np.round(values * 255).astype(np.uint8) if keep else None)


def encoder(edit, path, passno=None, passlog=None):
    p = edit.platform
    colours = ["-color_primaries", p["primaries"], "-color_trc", p["transfer"], "-colorspace", "bt709",
               "-color_range", "tv", "-chroma_sample_location", "left"]
    x264 = (f"colorprim={p['primaries']}:transfer={p['transfer']}:colormatrix=bt709:range=tv:chromaloc=0:"
            + p["x264"].format(fps=edit.fps, half=edit.fps // 2))
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "yuv420p",
               "-s", f"{edit.size[0]}x{edit.size[1]}", "-r", str(edit.fps), *colours, "-i", "-"]
    audio = p["audio"] and passno != 1
    if audio:
        command += ["-f", "lavfi", "-t", f"{edit.duration:.6f}", "-i", "anullsrc=r=48000:cl=stereo"]
    command += ["-map", "0:v"] + (["-map", "1:a", "-c:a", "aac", "-b:a", "128k"] if audio else [])
    command += ["-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-pix_fmt", "yuv420p", *colours]
    if "maxBytes" in p:
        rate = int(p["maxBytes"] * 8 / edit.duration * 0.97)
        command += ["-b:v", str(rate), "-pass", str(passno), "-passlogfile", str(passlog)]
    else:
        command += ["-crf", str(p["crf"])]
    command += ["-x264-params", x264]
    if passno == 1:
        command += ["-f", "null", "-"]
    else:
        # No edit list, as YouTube asks, so the B-frames' delay is taken up by negative composition offsets
        # instead: without them the first frame shows at 2 frames in, and AVFoundation leaves out the last two,
        # which then end after the track does (tried: 118 frames of 120; with them, 120 from 0, in Chromium too)
        command += ["-movflags", "+faststart+write_colr+negative_cts_offsets", "-use_editlist", "0", "-map_metadata", "-1",
                    "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", str(path)]
    return subprocess.Popen(command, stdin=subprocess.PIPE)


def make(name, workers):
    edit = Edit(name)
    stills = set(edit.stills())
    if edit.folder.exists():
        shutil.rmtree(edit.folder)
    (edit.folder / "stills").mkdir(parents=True)
    passes = [1, 2] if "maxBytes" in edit.platform else [None]
    passlog = edit.folder / "x264-pass"
    kept = {}
    with multiprocessing.get_context("spawn").Pool(workers, _open, (name,)) as pool:
        for passno in passes:
            video = encoder(edit, edit.path, passno, passlog)
            last = passno == passes[-1]
            waiting = collections.deque()

            def write(k, result):
                planes, values = result
                video.stdin.write(planes)
                if values is not None:
                    kept[k] = values
                print(f"\r{name}{f' (pass {passno})' if passno else ''}: {k + 1}/{len(edit.plan)}", end="", flush=True)

            for k, raw, size, entry in frames(edit):
                waiting.append((k, pool.apply_async(_render, ((raw, size, entry, last and k in stills),))))
                if len(waiting) > 2 * workers:
                    done, result = waiting.popleft()
                    write(done, result.get())
            while waiting:
                k, result = waiting.popleft()
                write(k, result.get())
            video.stdin.close()
            if video.wait():
                raise SystemExit(f"ffmpeg couldn't encode {edit.path.name}")
    for path in edit.folder.glob("x264-pass*"):
        path.unlink()
    print(f"\r{name}: {edit.path.relative_to(ROOT)}, {edit.duration:.1f} s, {edit.path.stat().st_size / 1e6:.1f} MB" + " " * 20)
    if "maxBytes" in edit.platform and edit.path.stat().st_size > edit.platform["maxBytes"]:
        raise SystemExit(f"{edit.path.name} is {edit.path.stat().st_size} bytes, more than {edit.platform['maxBytes']}")
    icc = bytes(Quartz.CGColorSpaceCopyICCData(Quartz.CGColorSpaceCreateWithName(pipeline.VIDEO_SPACES[edit.platform["space"]])))
    sheet = []
    for k in sorted(kept):
        Image.fromarray(kept[k]).save(edit.folder / "stills" / f"{k:04d}.png", icc_profile=icc)
        sheet.append(kept[k])
    contact_sheet(sheet, edit.platform["space"]).save(edit.folder / "sheet.png")


def contact_sheet(pictures, space, across=None, width=480):
    """The stills small, side by side, in sRGB, to look through"""
    across = across or (8 if pictures[0].shape[0] > pictures[0].shape[1] else 4)
    small = []
    for values in pictures:
        image = Image.fromarray(values)
        image = np.asarray(image.resize((width, round(width * image.height / image.width)), Image.LANCZOS))
        if space == "display-p3":
            image = np.round(in_space(image.astype(np.float32) / 255, "srgb") * 255).astype(np.uint8)
        small.append(image)
    h = small[0].shape[0]
    rows = -(-len(small) // across)
    sheet = np.zeros((rows * (h + 8), across * (width + 8), 3), np.uint8)
    for n, picture in enumerate(small):
        r, c = divmod(n, across)
        sheet[r * (h + 8):r * (h + 8) + h, c * (width + 8):c * (width + 8) + width] = picture
    return Image.fromarray(sheet)


# --- Checks ---------------------------------------------------------------------------------------

def decode(path, wanted, space):
    """The frames numbered in `wanted`, decoded by AVFoundation, as QuickTime Player and Safari decode them,
    asked for in the colours the video is tagged with, so nothing is matched: each one's number and values"""
    import AVFoundation
    asset = AVFoundation.AVURLAsset.URLAssetWithURL_options_(Foundation_url(path), None)
    track = asset.tracksWithMediaType_(AVFoundation.AVMediaTypeVideo)[0]
    if space == "display-p3":
        primaries, transfer = AVFoundation.AVVideoColorPrimaries_P3_D65, AVFoundation.AVVideoTransferFunction_IEC_sRGB
    else:
        primaries, transfer = AVFoundation.AVVideoColorPrimaries_ITU_R_709_2, AVFoundation.AVVideoTransferFunction_ITU_R_709_2
    settings = {Quartz.kCVPixelBufferPixelFormatTypeKey: Quartz.kCVPixelFormatType_64RGBAHalf,
                AVFoundation.AVVideoColorPropertiesKey: {
                    AVFoundation.AVVideoColorPrimariesKey: primaries,
                    AVFoundation.AVVideoTransferFunctionKey: transfer,
                    AVFoundation.AVVideoYCbCrMatrixKey: AVFoundation.AVVideoYCbCrMatrix_ITU_R_709_2}}
    reader = AVFoundation.AVAssetReader.alloc().initWithAsset_error_(asset, None)[0]
    output = AVFoundation.AVAssetReaderTrackOutput.alloc().initWithTrack_outputSettings_(track, settings)
    reader.addOutput_(output)
    reader.startReading()
    frame = 0
    import CoreMedia
    while (sample := output.copyNextSampleBuffer()) is not None:
        if frame in wanted:
            yield frame, pixel_buffer(CoreMedia.CMSampleBufferGetImageBuffer(sample))
        frame += 1
    yield None, frame


def verify(name):
    """The video decoded by AVFoundation against the values it was made from, on its stills' frames, and
    its length, tags and size"""
    edit = Edit(name)
    probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(edit.path)],
                                      capture_output=True, check=True).stdout)
    video = next(s for s in probe["streams"] if s["codec_type"] == "video")
    print(f"{edit.path.name}: {video['width']}×{video['height']}, {video['r_frame_rate']} fps, {video['profile']}, "
          f"{video.get('color_primaries')}/{video.get('color_transfer')}/{video.get('color_space')}/{video.get('color_range')}, "
          f"{float(probe['format']['duration']):.3f} s, {int(probe['format']['size'])} bytes, "
          f"streams: {', '.join(s['codec_name'] for s in probe['streams'])}")
    wanted = set(edit.stills())
    made = {}
    edit.prepare()
    for k, raw, size, entry in frames(edit):
        if k in wanted:
            made[k] = np.round(edit.picture(raw, size, entry) * 255)
    right = True
    for k, decoded in decode(edit.path, wanted, edit.platform["space"]):
        if k is None:
            print(f"  AVFoundation decodes {decoded} frames, {'as made' if decoded == len(edit.plan) else f'not the {len(edit.plan)} made'}")
            right = decoded == len(edit.plan)
            continue
        report(f"  frame {k}", np.round(np.clip(decoded, 0, 1) * 255), made[k])
    return right


def main():
    parser = argparse.ArgumentParser(description="Cuts Safelight's demo videos from the demo shots.")
    parser.add_argument("names", nargs="*", help="edits to make (all of scripts/demo/edits/ if none), or verify and edits")
    parser.add_argument("--workers", type=int, default=min(multiprocessing.cpu_count(), 8))
    args = parser.parse_args()
    names = args.names
    checking = names[:1] == ["verify"]
    names = (names[1:] if checking else names) or sorted(path.stem for path in EDITS.glob("*.json"))
    for name in names:
        if not (EDITS / f"{name}.json").exists():
            raise SystemExit(f"There's no scripts/demo/edits/{name}.json")
    if checking:
        if not all([verify(name) for name in names]):
            sys.exit(1)
    else:
        for name in names:
            make(name, args.workers)


if __name__ == "__main__":
    main()
