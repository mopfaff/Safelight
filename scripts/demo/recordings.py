#!/usr/bin/env python3
# Checks that the demo recorder gives the same recording every time, and says where two recordings differ
# when it doesn't. A recording is a folder with frames/NNNN.png and log.json, as scripts/make-demo.sh
# --record <scene> leaves in build/demo/recorder/recorded/<scene>/ (and a shot's folder, build/demo/<scene>/).
#
#   recordings.py repeat <scene> [-n 5] [--busy]
#                         records the scene n times with scripts/make-demo.sh --record and compares each
#                         recording with the first: the same, byte for byte (frames and log.json), or how they
#                         differ. With --busy, every core is kept busy meanwhile (a `yes` for each), which makes
#                         the Mac slow for as long as it takes: about 40 s a recording. The first recording and
#                         any that differ are kept in build/demo/recorder/repeated/<scene>/<number>/.
#   recordings.py compare <recording> <recording>...
#                         compares each recording with the first: which frames' pictures differ, in how many
#                         pixels and by how many levels of 255 at most, on which frames the logged knob of a
#                         slider differs and by how much, and which other parts of the log differ
#
# What the recorder prints as it ends says more when recordings differ (build/demo/recorder/<scene>.log):
# SwiftUI's time as the shot ended is the same every time for a scene, and the recorder fails if it isn't
# what its own frames add up to. How often the main thread read the scene's clock during the shot isn't:
# it differs by a few from one recording to the next, with the same frames. On 2026-11-19 recordings
# differed because SwiftUI's time began where the real clock had left it (recorder/main.swift, SwiftUITime).
#
# A log names the Mac's displays by their numbers, which change when the Mac restarts or a display is
# plugged in again, so recordings from either side of that differ in the log's displays, system and calls
# with the same frames.
import argparse, json, os, shutil, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
RECORDED = ROOT / "build" / "demo" / "recorder" / "recorded"
REPEATED = ROOT / "build" / "demo" / "recorder" / "repeated"


def runs(numbers):
    """Frame numbers as ranges: 128-142 215"""
    spans = []
    for number in numbers:
        if spans and number == spans[-1][1] + 1:
            spans[-1][1] = number
        else:
            spans.append([number, number])
    return " ".join(str(a) if a == b else f"{a}-{b}" for a, b in spans)


def differences(first, other):
    """How the recording in `other` differs from the one in `first`, in lines to print; none if it doesn't"""
    lines = []
    names = sorted(p.name for p in (first / "frames").iterdir())
    if names != sorted(p.name for p in (other / "frames").iterdir()):
        return [f"another number of frames: {len(names)} and {len(list((other / 'frames').iterdir()))}"]
    pictures = []
    for name in names:
        a, b = (first / "frames" / name).read_bytes(), (other / "frames" / name).read_bytes()
        if a == b:
            continue
        x = np.asarray(Image.open(first / "frames" / name).convert("RGBA")).astype(int)
        y = np.asarray(Image.open(other / "frames" / name).convert("RGBA")).astype(int)
        if x.shape != y.shape:
            return [f"frame {name} is another size"]
        apart = np.abs(x - y).max(axis=2)
        pictures.append((int(Path(name).stem), int((apart > 0).sum()), int(apart.max())))
    if pictures:
        lines.append(f"{len(pictures)} frames' pictures differ ({runs(p[0] for p in pictures)}): at most {max(p[1] for p in pictures)} pixels "
                     f"of a frame, by at most {max(p[2] for p in pictures)} levels")
    a, b = json.loads((first / "log.json").read_text()), json.loads((other / "log.json").read_text())
    top = [key for key in a if key != "frames" and a[key] != b.get(key)]
    if top:
        lines.append(f"the log's {', '.join(top)} differ")
    knobs, others = {}, {}
    for number, (x, y) in enumerate(zip(a["frames"], b["frames"])):
        for name, slider in x["sliders"].items():
            apart = abs(slider["knob"] - y["sliders"].get(name, slider)["knob"])
            if apart:
                knobs.setdefault(name, []).append((number, apart))
        for key in x:
            if key != "sliders" and x[key] != y.get(key):
                others.setdefault(key, []).append(number)
    for name, where in knobs.items():
        lines.append(f"{name}'s logged knob differs on {len(where)} frames ({runs(n for n, _ in where)}), by at most {max(d for _, d in where):.3g} "
                     f"of its value, first on frame {where[0][0]} by {where[0][1]:.3g}")
    for key, where in others.items():
        lines.append(f"the log's {key} differs on {len(where)} frames ({runs(where)})")
    if not lines and (first / "log.json").read_bytes() != (other / "log.json").read_bytes():
        lines.append("log.json differs, though not in what it says")
    return lines


def compare(recordings):
    same = True
    for other in recordings[1:]:
        lines = differences(recordings[0], other)
        same = same and not lines
        print(f"{other}: " + ("the same as the first, byte for byte" if not lines else "differs from the first"))
        for line in lines:
            print(f"    {line}")
    return same


def repeat(scene, count, busy):
    if not (ROOT / "scripts" / "demo" / "scenes" / f"{scene}.json").exists():
        sys.exit(f"There's no scene called {scene}")
    folder = REPEATED / scene
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    load = [subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(os.cpu_count() if busy else 0)]
    same = True
    try:
        for number in range(1, count + 1):
            made = subprocess.run([str(ROOT / "scripts" / "make-demo.sh"), "--record", scene], capture_output=True, text=True)
            if made.returncode:
                sys.exit(f"Recording {number} failed:\n{made.stdout}{made.stderr}")
            clock = next((line for line in made.stdout.splitlines() if line.startswith("The scene's clock")), "")
            shutil.copytree(RECORDED / scene, folder / str(number))
            if number == 1:
                print(f"1: {clock}")
                continue
            lines = differences(folder / "1", folder / str(number))
            print(f"{number}: " + ("the same as the first, byte for byte" if not lines else "differs from the first") + f". {clock}")
            for line in lines:
                print(f"    {line}")
            if lines:
                same = False
            else:
                shutil.rmtree(folder / str(number))
    finally:
        for process in load:
            process.kill()
    frames = len(list((folder / "1" / "frames").iterdir()))
    print(f"{scene}: {count} recordings" + (" with every core busy" if busy else "") + (f" the same, byte for byte ({frames} frames and log.json)" if same
          else f", not all the same; the first and those that differ are in {folder.relative_to(ROOT)}"))
    return same


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Checks that the demo recorder gives the same recording every time")
    commands = parser.add_subparsers(dest="command", required=True)
    again = commands.add_parser("repeat")
    again.add_argument("scene")
    again.add_argument("-n", type=int, default=5)
    again.add_argument("--busy", action="store_true")
    pair = commands.add_parser("compare")
    pair.add_argument("recordings", nargs="+", type=Path)
    args = parser.parse_args()
    if args.command == "repeat":
        sys.exit(0 if repeat(args.scene, args.n, args.busy) else 1)
    if len(args.recordings) < 2:
        sys.exit("Give two recordings or more")
    sys.exit(0 if compare(args.recordings) else 1)
