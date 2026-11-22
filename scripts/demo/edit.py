#!/usr/bin/env python3
# Cuts Safelight's demo videos from the finished demo shots (scripts/make-demo.sh <scene>), as each edit
# file in scripts/demo/edits/ has it: which shots, from when to when in each, the words with them (a label
# for each shot, captions, a clock) and an end card, and the platform the video is for, which sets its
# colours and how it's encoded. Run it with scripts/make-demo.sh --edit, which draws Safelight's icon for
# the label and the end card first.
#
#   edit.py [<edit>...]          writes build/demo/edits/<edit>/safelight-<edit>.mp4 for each edit named, or
#                                for all of them, with stills/ (frames of it as PNGs: a little way in, the
#                                middle of each caption, the end card) and sheet.png (all of them, small)
#   edit.py verify [<edit>...]   decodes the videos as macOS's players do (AVFoundation), in each video's own
#                                colours, and compares them with the frames they were made from
#
# Only editorial things happen here: cuts between shots, the words, the end card faded in over the last shot.
# Nothing changes what a screen shows inside a shot. The words go in the black a shot's panes leave round
# them: white, left-aligned, on nothing. The clock is the one thing here that reads a shot's recording: the
# time of day on each of its frames, from the log beside its master (log.json's "timeOfDay"). It's drawn
# here and not into the master by compose.py as it belongs with the label, on its line and in its type,
# which each edit places for its own shape; so a master stays the screens alone, every value as the
# display maths made it, and the words can change without a shot being made again. Each shot's master (its <scene>-<camera>.mkv, Display
# P3, 10 bits, every value as compose.py made it; or the .mp4, in HEVC, of a shot made before 19 November
# 2026) is decoded here as it was encoded (compose.ycbcr: BT.709's luma and chroma at video's
# limited range, chroma at the left of its two columns), so the values are the master's own; a 16:9 master,
# 3840×2160, is halved to 1920×1080 by averaging each 2×2 pixels' light, as compose.py's camera scales.
#
# Each platform's colours, as found on 4 November 2026, not assumed:
#   youtube  YouTube's upload settings (support.google.com/youtube/answer/1722171) want SDR in BT.709 and
#            convert anything else themselves; a wide gamut only comes as HDR (BT.2020 with PQ or HLG). So the
#            P3 values are matched to sRGB's primaries here, the deepest reds clipped, and tagged BT.709 all
#            through. Their curve is sRGB's: Chromium shows BT.709's tone curve and sRGB's alike (a grey of
#            128 drawn as 128 either way, tried with tagged videos), and tagged with sRGB's curve, YouTube
#            would re-encode them to BT.709's, which Chromium then shows darker. 60 fps H.264 as YouTube asks: High profile, a closed GOP of half the frame rate, 2 B-frames
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
#   "words"      where the words go, in pixels of the shots' masters, as their panes are, whatever the
#                video's size: "label", "clock" and "caption", each {"x", "y", "size"}: the left edge of the
#                label and of the captions, and the right edge of the clock, at x; the middle of their
#                height at y (of all a caption's lines together); the size of their type
#   "clips"      in order, each {"shot", "from", "to"}, in seconds of the shot, with "label", the words over
#                the shot all through it ("icon": true puts Safelight's icon before them), "clock": true for
#                the time of day the shot's clock reads on each frame (HH:MM, its digits all as wide, so
#                it stays put as they change), and its "captions": each {"from", "to", in seconds of the
#                shot, "text" (a line, or a list of them), "small" (a smaller, greyer line under it)}. A
#                caption fades in, unless it's there as the clip starts, and out, unless it lasts until
#                the clip is cut or the next one comes as it goes
#   "endCard"    {"duration", "fade" (over the end of the last clip), "lines"}: Safelight's icon over black,
#                with its name and the lines under it, or null for none
#
# Re-running gives the same files, byte for byte. Needs what compose.py needs.
import argparse, collections, copy, functools, json, math, multiprocessing, shutil, subprocess, sys
from pathlib import Path
import numpy as np
import Quartz
from PIL import Image, ImageDraw, ImageFont
import pipeline
from compose import Foundation_url, pixel_buffer, report, rgb_from_ycbcr, ycbcr

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
    "web": {"space": "srgb", "primaries": "bt709", "transfer": "bt709", "audio": False, "crf": 16,
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
            # The master as compose.py makes it, or as it did before 19 November 2026
            named = BUILD / clip["shot"] / f"{clip['shot']}-{camera.replace(':', 'x')}"
            master = next((path for path in (named.with_name(named.name + end) for end in (".mkv", ".mp4")) if path.exists()), None)
            if not master:
                raise SystemExit(f"There's no {named.relative_to(ROOT)}.mkv: make it with scripts/make-demo.sh {clip['shot']}")
            size = tuple(scene["camera"][camera]["size"])
            scale = size[0] // self.size[0]
            if size[0] != self.size[0] * scale or size[1] != self.size[1] * scale:
                raise SystemExit(f"{self.name}: {clip['shot']}'s {camera} is {size[0]}×{size[1]}, not {self.size[0]}×{self.size[1]} or a whole multiple of it")
            if scene["fps"] % self.fps or not 0 <= clip["from"] < clip["to"] <= scene["duration"]:
                raise SystemExit(f"{self.name}: {clip['shot']} is {scene['duration']} s at {scene['fps']} fps; can't cut {clip['from']}–{clip['to']} s at {self.fps} fps")
            times = None
            if clip.get("clock"):
                # The time of day on each of the shot's frames, as its recording's log has it
                times = [frame.get("timeOfDay") for frame in json.loads((master.parent / "log.json").read_text())["frames"]]
                if not all(times):
                    raise SystemExit(f"{self.name}: {clip['shot']} has no clock of its own to show")
            self.clips.append(dict(clip, master=master, size=size, shot_fps=scene["fps"], times=times))
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
                    on.append((n, appear * leave))
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
            for i, opacity in entry.captions:
                shown[i].append(k)
        frames |= {ks[len(ks) // 2] for ks in shown.values()}
        if self.card:
            frames.add(len(self.plan) - round(self.card["duration"] * self.fps * 0.4))
        return sorted(frames)

    # The pictures over the shots, made once in each worker

    def prepare(self):
        words = self.spec["words"]
        # The words' places are in the masters' pixels: so much of one in the video's
        self.k = k = self.size[0] / self.clips[0]["size"][0]
        self.caption_art = []
        for caption in self.captions:
            lines = [caption["text"]] if isinstance(caption["text"], str) else list(caption["text"])
            spec = words["caption"]
            size = spec["size"] * k
            # As tall as the storyboard has them: a line 1.22 of its type's size, the small one 0.66 of that type
            line_h, small_h = size * 1.22, size * 0.66 * 1.3 if caption.get("small") else 0
            top = spec["y"] * k - (line_h * len(lines) + small_h) / 2
            art = [line_picture(line, spec["x"] * k, top + line_h * (n + 0.5), size, "Semibold", WHITE) for n, line in enumerate(lines)]
            if caption.get("small"):
                art.append(line_picture(caption["small"], spec["x"] * k, top + line_h * len(lines) + small_h * 0.5, size * 0.66, "Medium", GREY))
            for picture, x, y in art:
                if x + picture.shape[1] > self.size[0] - spec["x"] * k or y < 0 or y + picture.shape[0] > self.size[1]:
                    raise SystemExit(f"{self.name}: the caption {caption['text']!r} doesn't fit in the video from where it starts")
            self.caption_art.append(art)
        # Each clip's label, Safelight's icon before it if asked for, half as tall again as its type
        self.label_art = []
        for clip in self.clips:
            art = []
            if label := clip.get("label"):
                spec = words["label"]
                x, y, size = spec["x"] * k, spec["y"] * k, spec["size"] * k
                if clip.get("icon"):
                    side = round(size * 1.5)
                    icon = Image.open(ICON).convert("RGBA").convert("RGBa").resize((side, side), Image.LANCZOS).convert("RGBA")
                    icon = np.asarray(icon, np.float32) / 255
                    icon[..., :3] = in_space(icon[..., :3], self.platform["space"])
                    # The icon's picture has room round its shape, so it starts a little left of the words' edge
                    art.append((icon, round(x - side * 0.1), round(y - side / 2)))
                    x += side * 0.95
                art.append(line_picture(label, x, y, size, "Semibold", WHITE))
            self.label_art.append(art)
        self.card_values = end_card(self.size, self.card["lines"], self.platform["space"]) if self.card else None

    @functools.lru_cache(maxsize=None)
    def clock_art(self, time):
        """The clock reading `time`, HH:MM, its right edge where the edit has it: in digits all as wide (the
        type's own, "tnum"), so each stays where it is as the minutes go by"""
        spec = self.spec["words"]["clock"]
        return line_picture(time, spec["x"] * self.k, spec["y"] * self.k, spec["size"] * self.k, "Bold", WHITE, anchor="rm", features=("tnum",))

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
        for art, x, y in self.label_art[entry.clip]:
            over(values, art, x, y)
        if times := self.clips[entry.clip]["times"]:
            over(values, *self.clock_art(times[entry.frame][:5]))
        for i, opacity in entry.captions:
            for art, x, y in self.caption_art[i]:
                over(values, art, x, y, opacity)
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


WHITE, GREY = (1.0, 1.0, 1.0), (176 / 255, 176 / 255, 186 / 255)


def line_picture(text, x, y, size, weight, colour, anchor="lm", features=None, supersample=4):
    """A line of words in SF Pro, in one colour on nothing: its picture (straight alpha) and the pixel its
    top left goes at, for the line's left edge ("lm", or its right, "rm") to be at x and the middle of its
    type's height at y, in pixels of the video, which needn't be whole ones. Drawn at 4 times the size and
    averaged down, so it's as sharp wherever it falls on the pixels."""
    s = supersample
    face = font(round(size * s), weight)
    ax, ay = round(x * s), round(y * s)
    left, top, right, bottom = face.getbbox(text, anchor=anchor, features=features)
    x0, y0 = math.floor((ax + left) / s) - 1, math.floor((ay + top) / s) - 1
    x1, y1 = math.ceil((ax + right) / s) + 1, math.ceil((ay + bottom) / s) + 1
    mask = Image.new("L", ((x1 - x0) * s, (y1 - y0) * s), 0)
    ImageDraw.Draw(mask).text((ax - x0 * s, ay - y0 * s), text, font=face, fill=255, anchor=anchor, features=features)
    picture = np.empty((y1 - y0, x1 - x0, 4), np.float32)
    picture[..., :3] = colour
    picture[..., 3] = np.asarray(mask.resize((x1 - x0, y1 - y0), Image.BOX), np.float32) / 255
    return picture, x0, y0


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
