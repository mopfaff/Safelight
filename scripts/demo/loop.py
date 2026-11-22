#!/usr/bin/env python3
# Cuts a picture that plays by itself, over and over, from a finished demo shot (scripts/make-demo.sh
# <scene>), as each loop file in scripts/demo/loops/ has it: for a README, where a video has to be
# clicked and a picture doesn't. Run it with scripts/make-demo.sh --loop.
#
#   loop.py [<loop>...]          writes build/demo/loops/<loop>/<loop>.avif and <loop>.webp for each loop
#                                named, or for all of them, with frames/ (each of its pictures as it was
#                                made, a PNG) and preview.html (both on a README's page, light and dark),
#                                and then checks them as verify does
#   loop.py verify [<loop>...]   decodes both files again and compares them with those frames
#
# Why two files, and no GIF, measured on the Color filter shot (1856×1020, 8.7 s at 30 fps) on 21 November
# 2026. A screen that fades to red changes everywhere on every frame, a photograph under it:
#   AVIF   AV1 video in a picture's file, so a frame can be stored as what changed since the one before.
#          Chrome, Safari (16.4 on) and Firefox (113 on) play it in an <img>; whether a README on GitHub
#          does hadn't been tried when this was written. Stored the smallest way, one whole frame and then
#          changes only, in 4:4:4, it was 3.5 MB with 87% of its pixels within 3 levels of 255 of the frames
#          made, and Safari stuttered through it with five cores busy: macOS's decoder (ImageIO, which
#          hands AV1 to VideoToolbox) builds every frame it's asked for from the last whole one, so a frame
#          took 0.3 s on average and the last 0.66 s, where it has 0.033; and VideoToolbox decodes 4:4:4 on
#          the CPU. So the AVIF has a whole frame at least every "keyframes" frames and is 4:2:0, which
#          Macs with an AV1 decoder (M3 on) decode in hardware: at 15, 4.3 MB, 84% within 3 levels (82% of
#          a fully red frame, whose detail is mostly in the halved chroma; 94% in 4:4:4), a frame in 26 ms
#          on an M4 Pro. In 4:4:4 it was 6.3 MB and 50 ms a frame, 8.9 MB and 41 ms with a whole frame
#          every 8. How a Mac without the hardware decoder plays it wasn't tried.
#   WebP   an animated WebP is reported to play in a README on GitHub (github.com/TomasHubelbauer/
#          markdown-webp; not tried here). But libwebp leaves out any block of a frame within a few
#          levels (4 at quality 80) of the frame before, and compares the frames it's given, not what it
#          has drawn: in a slow fade no frame is ever far enough from the last, so blocks of the screen
#          stayed as they were while the rest went red (up to 137 levels off). So every frame is stored
#          whole here ("kmax" 1), which is 18 MB at quality 80 and 11 MB at 60, and further from the frames
#          made than the AVIF (67% and 61% within 3 levels).
#   GIF    256 colours a frame, which bands the fade, and larger again.
#
# The picture is the shot's panes alone, as its camera has them, cut out of the master where they are
# and see-through everywhere else, so it sits on the page's own colour, light or dark. Nothing changes
# what a pane shows: the master's values (edit.py's Master, Display P3, every value as compose.py made
# it) are made smaller by averaging each "scale" × "scale" pixels' light, as edit.py halves them, and
# matched to sRGB's primaries, the deepest reds clipped, as the X and YouTube videos are: the pictures
# are 8 bits, and a browser takes one without a profile for sRGB.
#
# A loop file (scripts/demo/loops/<loop>.json):
#   "shot", "camera"   the shot and which of its cameras' masters
#   "from", "to"       in seconds of the shot
#   "fps"              of the loop: the shot's, or a whole part of it
#   "scale"            how many of the master's pixels across go into one of the loop's (a whole number)
#   "hold"             seconds the last frame stays before the loop goes round
#   "dissolve"         seconds over which the last frame turns into the first, for a shot that doesn't end
#                      as it began; 0 for one that does
#   "avif", "webp"     each file's quality, 0...100
#   "keyframes"        the most frames the AVIF goes without a whole one; "yuv" its chroma, 420 or 444
#   "width"            how wide a README shows it, in points, for preview.html
#   "caption"          the line a README has above it, for preview.html
#
# The check also times macOS's decoder on every frame of each file, as Safari asks for them, and says so
# when a frame takes longer on average than it shows for.
#
# Needs what edit.py needs, and avifenc and avifdec (brew install libavif); Pillow writes the WebP.
import argparse, json, multiprocessing, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path
import numpy as np
import Quartz
from Foundation import NSURL
from PIL import Image
from compose import rgb_from_ycbcr
from edit import BUILD, ROOT, SCENES, Master, in_space, smooth, to_light, to_values

LOOPS = ROOT / "scripts" / "demo" / "loops"
OUT = BUILD / "loops"


class Loop:
    """A loop file, and what's on each of its frames: (the shot's frame, the frame it's turning into or
    None, how far, 0...1, and for how many milliseconds it shows)"""

    def __init__(self, name):
        self.name = name
        self.spec = spec = json.loads((LOOPS / f"{name}.json").read_text())
        scene = json.loads((SCENES / f"{spec['shot']}.json").read_text())
        camera = scene["camera"][spec["camera"]]
        self.master_size = tuple(camera["size"])
        self.master = BUILD / spec["shot"] / f"{spec['shot']}-{spec['camera'].replace(':', 'x')}.mkv"
        if not self.master.exists():
            raise SystemExit(f"There's no {self.master.relative_to(ROOT)}: make it with scripts/make-demo.sh {spec['shot']}")
        self.fps, self.scale = spec["fps"], spec["scale"]
        if scene["fps"] % self.fps or not 0 <= spec["from"] < spec["to"] <= scene["duration"]:
            raise SystemExit(f"{name}: {spec['shot']} is {scene['duration']} s at {scene['fps']} fps; can't cut {spec['from']}–{spec['to']} s at {self.fps} fps")
        # The panes, in the master's pixels, and the box round them all, which is the loop's picture
        panes = [tuple(pane["rect"]) for pane in camera["panes"]]
        x0, y0 = min(p[0] for p in panes), min(p[1] for p in panes)
        x1, y1 = max(p[0] + p[2] for p in panes), max(p[1] + p[3] for p in panes)
        self.box = (x0, y0, x1, y1)
        self.panes = [(x - x0, y - y0, w, h) for x, y, w, h in panes]
        if any(v % self.scale for pane in self.panes for v in pane) or (x1 - x0) % self.scale or (y1 - y0) % self.scale:
            raise SystemExit(f"{name}: {spec['shot']}'s panes aren't on whole pixels at 1/{self.scale} of the master's size")
        self.size = ((x1 - x0) // self.scale, (y1 - y0) // self.scale)
        self.folder = OUT / name
        self.avif, self.webp = self.folder / f"{name}.avif", self.folder / f"{name}.webp"
        self.plan = self._plan(scene["fps"])

    def _plan(self, shot_fps):
        spec = self.spec
        step = shot_fps // self.fps
        first = round(spec["from"] * shot_fps)
        count = round((spec["to"] - spec["from"]) * self.fps)
        hold, fade = round(spec.get("hold", 0) * self.fps), round(spec.get("dissolve", 0) * self.fps)
        frames = [(first + k * step, None, 0.0) for k in range(count)]
        last = frames[-1][0]
        frames += [(last, None, 0.0)] * hold
        frames += [(last, first, smooth((j + 0.5) / fade)) for j in range(fade)]
        # Whole milliseconds, as a WebP's frames have them, that add up to the loop's own length
        at = [round(1000 * k / self.fps) for k in range(len(frames) + 1)]
        return [frame + (at[k + 1] - at[k],) for k, frame in enumerate(frames)]

    def preview(self):
        """A page with the loop as a README would show it, one file at a time (each one playing costs a
        decoder), on GitHub's light or dark page colours"""
        width, caption = self.spec.get("width", self.size[0] // 2), self.spec.get("caption", "")
        files = "".join(f'<button data-file="{file.name}">{file.suffix[1:].upper()}, {file.stat().st_size / 1e6:.1f} MB</button>' for file in (self.avif, self.webp))
        (self.folder / "preview.html").write_text(
            f'<!doctype html><meta charset="utf-8"><title>{self.name}</title><style>body{{margin:0;font:16px -apple-system,sans-serif;min-height:100vh}}'
            f'body.light{{background:#fff;color:#1f2328}}body.dark{{background:#0d1117;color:#f0f6fc}}'
            f'main{{padding:24px max(16px,calc(50% - 440px))}}nav{{margin:0 0 24px;display:flex;gap:8px}}'
            f'button{{font:13px -apple-system,sans-serif;padding:4px 10px;border-radius:6px;border:1px solid #8884;background:none;color:inherit}}'
            f'button.on{{background:#8883}}img{{max-width:100%;height:auto}}</style>'
            f'<body class="light"><main><nav>{files}<button data-look="light">Light page</button><button data-look="dark">Dark page</button></nav>'
            f'<p>{caption}</p><p align="center"><img width="{width}"></p></main><script>'
            f'const img=document.querySelector("img"),buttons=[...document.querySelectorAll("button")];let file="{self.avif.name}",look="light";'
            f'function show(){{img.src=file;document.body.className=look;buttons.forEach(b=>b.classList.toggle("on",b.dataset.file===file||b.dataset.look===look))}}'
            f'buttons.forEach(b=>b.onclick=()=>{{file=b.dataset.file||file;look=b.dataset.look||look;show()}});show()</script>')

    def picture(self, raw, towards=None, mix=0.0):
        """A frame of the master as the loop's picture: RGBA, 8 bits, sRGB, see-through outside the panes"""
        x0, y0, x1, y1 = self.box

        def values(raw):
            v = rgb_from_ycbcr(raw, *self.master_size)[y0:y1, x0:x1]
            if self.scale > 1:
                w, h = self.size
                v = to_values(to_light(v).reshape(h, self.scale, w, self.scale, 3).mean(axis=(1, 3)))
            return in_space(v, "srgb")

        v = values(raw)
        if towards is not None:
            v = v * (1 - mix) + values(towards) * mix
        w, h = self.size
        picture = np.zeros((h, w, 4), np.uint8)
        s = self.scale
        for x, y, pw, ph in self.panes:
            area = (slice(y // s, (y + ph) // s), slice(x // s, (x + pw) // s))
            picture[area + (slice(0, 3),)] = np.round(v[area] * 255)
            picture[area + (3,)] = 255
        return picture


_loop = None


def _open(name):
    global _loop
    _loop = Loop(name)


def _render(task):
    k, raw, towards, mix = task
    path = _loop.folder / "frames" / f"{k:04d}.png"
    Image.fromarray(_loop.picture(raw, towards, mix)).save(path)
    return k


def make(name, workers):
    loop = Loop(name)
    if loop.folder.exists():
        shutil.rmtree(loop.folder)
    (loop.folder / "frames").mkdir(parents=True)
    # The master's frames come in order; the two a dissolve is between are kept as they pass
    wanted = sorted({f for frame, towards, mix, ms in loop.plan for f in (frame, towards) if f is not None})
    kept = {f for frame, towards, mix, ms in loop.plan if towards is not None for f in (frame, towards)}
    master = Master({"size": loop.master_size, "master": loop.master})
    raws = {}
    done = 0
    with multiprocessing.get_context("spawn").Pool(workers, _open, (name,)) as pool:
        waiting = []
        plain = {frame: k for k, (frame, towards, mix, ms) in enumerate(loop.plan) if towards is None}
        count = len(plain) + sum(1 for entry in loop.plan if entry[1] is not None)

        def finished():
            nonlocal done
            waiting.pop(0).get()
            done += 1
            print(f"\r{name}: {done}/{count}", end="", flush=True)

        for f in wanted:
            raw = master.frame(f)
            if f in kept:
                raws[f] = raw
            if f in plain:
                # A frame that's held is made once, as the last of its run
                waiting.append(pool.apply_async(_render, ((plain[f], raw, None, 0.0),)))
            if len(waiting) > 2 * workers:
                finished()
        master.close()
        for k, (frame, towards, mix, ms) in enumerate(loop.plan):
            if towards is not None:
                waiting.append(pool.apply_async(_render, ((k, raws[frame], raws[towards], mix),)))
        while waiting:
            finished()
    # Frames that are the same as the one before are one frame shown for longer
    frames, shown = [], []
    made = {frame: k for k, (frame, towards, mix, ms) in enumerate(loop.plan) if towards is None}
    previous = None
    for k, (frame, towards, mix, ms) in enumerate(loop.plan):
        path = loop.folder / "frames" / f"{made[frame] if towards is None else k:04d}.png"
        values = np.asarray(Image.open(path))
        if previous is not None and np.array_equal(values, previous):
            shown[-1] += ms
        else:
            frames.append(path)
            shown.append(ms)
        previous = values
    used = set(frames)
    for path in (loop.folder / "frames").iterdir():
        if path not in used:
            path.unlink()
    (loop.folder / "frames.json").write_text(json.dumps([{"frame": path.name, "ms": ms} for path, ms in zip(frames, shown)], indent=1))
    command = ["avifenc", "--timescale", "1000", "--repetition-count", "infinite", "-q", str(loop.spec["avif"]),
               "--qalpha", "100", "-s", "6", "-j", "4", "--yuv", str(loop.spec["yuv"]), "--keyframe", str(loop.spec["keyframes"])]
    for path, ms in zip(frames, shown):
        command += ["--duration", str(ms), str(path)]
    if subprocess.run(command + [str(loop.avif)], capture_output=True).returncode:
        raise SystemExit(f"avifenc couldn't write {loop.avif.name}")
    # Every frame whole ("kmax" 1): see the top of this file
    pictures = [Image.open(path) for path in frames]
    pictures[0].save(loop.webp, save_all=True, append_images=pictures[1:], duration=shown, loop=0,
                     quality=loop.spec["webp"], method=4, lossless=False, kmax=1)
    loop.preview()
    print(f"\r{name}: {loop.size[0]}×{loop.size[1]}, {len(frames)} frames, {sum(shown) / 1000:.1f} s: "
          + ", ".join(f"{path.relative_to(ROOT)} {path.stat().st_size / 1e6:.2f} MB" for path in (loop.avif, loop.webp)))


def closeness(decoded, made):
    """How far a decoded frame's values are from the frame made, where it isn't see-through"""
    return np.abs(decoded[..., :3].astype(np.int16) - made[..., :3].astype(np.int16)).max(axis=2)[made[..., 3] > 0]


def decoding(path):
    """How long macOS's decoder takes over a frame of the file, in milliseconds: the average and the slowest,
    each frame asked of ImageIO in turn and drawn, as Safari does to play it"""
    source = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(path)), None)
    space = Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceSRGB)
    times = []
    for k in range(Quartz.CGImageSourceGetCount(source)):
        start = time.perf_counter()
        image = Quartz.CGImageSourceCreateImageAtIndex(source, k, None)
        width, height = Quartz.CGImageGetWidth(image), Quartz.CGImageGetHeight(image)
        context = Quartz.CGBitmapContextCreate(None, width, height, 8, 0, space, Quartz.kCGImageAlphaPremultipliedLast)
        Quartz.CGContextDrawImage(context, ((0, 0), (width, height)), image)
        times.append(1000 * (time.perf_counter() - start))
    return sum(times) / len(times), max(times)


def said(path, frames, offs, length, made_length, shortest):
    off = np.concatenate(offs)
    average, slowest = decoding(path)
    print(f"  {path.name}: macOS decodes a frame in {average:.0f} ms on average, the slowest in {slowest:.0f}"
          + (f": too slow for Safari to play it smoothly on this Mac, a frame lasting {shortest} ms" if average > shortest else f" (a frame lasts {shortest} ms)"))
    print(f"  {path.name}: {path.stat().st_size / 1e6:.2f} MB, {frames} frames; of the panes' pixels {100 * (off <= 3).mean():.1f}% within 3 levels "
          f"of 255 of the frames made, {100 * (off <= 6).mean():.1f}% within 6, the worst {off.max()} off; {length / 1000:.3f} s a round, "
          f"{'as made' if length == made_length else f'not the {made_length / 1000:.3f} made'}")


def verify(name):
    """Both files decoded again against the frames they were made from, each frame against the one made
    for the time it comes at (the WebP's encoder leaves out a frame that's within a few levels of the one
    before, so it can have fewer than were made), and whether each goes round for ever, in the time made"""
    loop = Loop(name)
    listed = json.loads((loop.folder / "frames.json").read_text())
    starts, length = {}, 0
    for entry in listed:
        starts[length] = entry["frame"]
        length += entry["ms"]
    made = lambda at: np.asarray(Image.open(loop.folder / "frames" / starts[at]))
    shortest = min(entry["ms"] for entry in listed)
    right = True
    print(f"{name}: {loop.size[0]}×{loop.size[1]}, {len(listed)} frames made")

    # The AVIF, by libavif's own decoder: its frames' times as it reports them, then every frame
    info = subprocess.run(["avifdec", "--info", str(loop.avif)], capture_output=True, text=True, check=True).stdout
    times = [int(ms) for ms in re.findall(r"\[duration [\d.]+ \((\d+) timescales\)\]", info)]
    right &= "Repeat Count   : Infinite" in info and times == [entry["ms"] for entry in listed]
    with tempfile.TemporaryDirectory() as folder:
        subprocess.run(["avifdec", "--index", "all", str(loop.avif), f"{folder}/f.png"], capture_output=True, check=True)
        offs, at = [], 0
        for k, ms in enumerate(times):
            decoded = np.asarray(Image.open(f"{folder}/f-{k:010d}.png").convert("RGBA"))
            right &= at in starts and np.array_equal(decoded[..., 3], made(at)[..., 3])
            if at not in starts:
                break
            offs.append(closeness(decoded, made(at)))
            at += ms
    said(loop.avif, len(times), offs, at, length, shortest)

    image = Image.open(loop.webp)
    right &= image.info.get("loop") == 0
    offs, at = [], 0
    for k in range(image.n_frames):
        image.seek(k)
        image.load()
        if at not in starts:
            right = False
            break
        decoded = np.asarray(image.convert("RGBA"))
        right &= np.array_equal(decoded[..., 3], made(at)[..., 3])
        offs.append(closeness(decoded, made(at)))
        at += image.info["duration"]
    said(loop.webp, image.n_frames, offs, at, length, shortest)
    right &= at == length
    if not right:
        print("  not as made: a frame at a time none was made for, see-through in other places, or not going round for ever in the time made")
    return bool(right)


def main():
    parser = argparse.ArgumentParser(description="Cuts pictures that play by themselves from Safelight's demo shots.")
    parser.add_argument("names", nargs="*", help="loops to make (all of scripts/demo/loops/ if none), or verify and loops")
    parser.add_argument("--workers", type=int, default=min(multiprocessing.cpu_count(), 6))
    args = parser.parse_args()
    names = args.names
    checking = names[:1] == ["verify"]
    names = (names[1:] if checking else names) or sorted(path.stem for path in LOOPS.glob("*.json"))
    for name in names:
        if not (LOOPS / f"{name}.json").exists():
            raise SystemExit(f"There's no scripts/demo/loops/{name}.json")
    for name in names:
        if not checking:
            make(name, args.workers)
        if not verify(name):
            sys.exit(1)


if __name__ == "__main__":
    main()
