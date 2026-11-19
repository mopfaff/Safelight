#!/usr/bin/env python3
# Makes a storyboard of the demo, to look at before any shot is made: stills of each shot in the layout it
# would have, with its label and captions over them, and one sheet of them all with what each shot shows.
# The stills are frames of finished recordings (build/demo/<scene>/, or a draft's in build/demo/drafts/),
# composed as scripts/demo/compose.py composes a shot's videos, light and all, but filmed by the
# storyboard's own cameras: the layout's panes, each a fixed view. So a new layout needs no new recording.
#
#   storyboard.py [<storyboard>]   reads scripts/demo/storyboard/<storyboard>.json (reshoot, unless named)
#                                  and writes build/demo/storyboard/<storyboard>.png, the sheet, and
#                                  <storyboard>/, each still at half the video's size, in sRGB
#
# A storyboard file:
#   "layouts"   by shape (16:9, 9:16): "size" of the video in pixels, and "panes", by name: the "rect" of the
#               video each fills (left, top, width, height) and its view of the stage, "centre" and "height"
#               in points, as a camera's key in a scene has them. "label", "clock" and "caption" say where the
#               words go: "x", "y" (the middle of their height) and "size" in pixels, "align" left, centre or
#               right of x
#   "document"  the window on the desktop: its "frame" on the popover's display (left, top, width, height in
#               points). It's the storyboard's stand-in for a real app's window: a real AppKit window with a
#               text document, pictured by the window server in Light and Dark (storyboard/DocumentWindow.swift,
#               built and run here when its pictures are missing; nothing shows on screen), put over the
#               desktop under the popover's layer as the window server puts one window's picture over what's
#               behind, in the menu bar's appearance on that frame. It has to be clear of the popover: the
#               popover's glass was recorded over the desktop without it
#   "shots"     in order, each with "name", "from" and "to" in seconds of the video, "label" (the words over
#               the screen), "what" (what happens, for the sheet), and "stills": each the "recording" (a scene's
#               name, or drafts/<scene>) and "frame" it's of, the "layout" (16:9 unless given), "caption"
#               and "small" (the words under the screen then), "label" (if not the shot's), "icon" (true:
#               Safelight's icon before the label), "clock" (true: the scene's time of day on that
#               frame, large), "views" (a pane's view, if not the layout's), "document" (false: no window)
#               and "note" (how the shot as re-made will differ from this still). "picture" instead of a
#               recording is a finished picture's path under build/demo/, shown as it is
#
# Needs what compose.py needs, and swiftc for the document window's pictures.
import argparse, json, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import compose, pipeline

ROOT = Path(__file__).resolve().parents[2]
BOARDS = ROOT / "scripts" / "demo" / "storyboard"
BUILD = ROOT / "build" / "demo"
OUT = BUILD / "storyboard"
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight="Semibold"):
    f = ImageFont.truetype(FONT, round(size))
    f.set_variation_by_name(weight)
    return f


# --- The document window --------------------------------------------------------------------------

def document_pictures(size):
    """The window server's pictures of the document window, Light and Dark, taken when they're missing or
    of another size: DocumentWindow.swift, built here. Each as its values (straight alpha), its colour
    profile, and where the window's own top left is in it, in pixels"""
    folder = OUT / "window"
    about = folder / "about.json"
    wanted = {"size": list(size), "source": (ROOT / "scripts/demo/storyboard/DocumentWindow.swift").read_text()}
    if not about.exists() or json.loads(about.read_text()) != wanted:
        folder.mkdir(parents=True, exist_ok=True)
        tool = folder / "DocumentWindow"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-o", str(tool), str(ROOT / "scripts/demo/storyboard/DocumentWindow.swift")], check=True)
        subprocess.run([str(tool), str(folder), str(size[0]), str(size[1])], check=True)
        about.write_text(json.dumps(wanted))
    pictures = {}
    for appearance in ("light", "dark"):
        pixels, icc = compose.read_png(folder / f"window-{appearance}.png")
        solid = pixels[..., 3] == 1
        h, w = solid.shape
        top, left = int(np.argmax(solid[:, w // 2])), int(np.argmax(solid[h // 2]))
        if not solid[top, w // 2] or (w - left - int(np.argmax(solid[h // 2, ::-1])), h - top - int(np.argmax(solid[::-1, w // 2]))) != (size[0] * 2, size[1] * 2):
            raise SystemExit(f"window-{appearance}.png isn't a picture of a window {size[0]}×{size[1]} points")
        pictures[appearance] = (pixels, icc, (left, top))
    return pictures


class Recording(compose.Shot):
    """A recorded scene with the storyboard's document window on its desktop"""

    def __init__(self, scene, folder, document):
        self.document = None
        super().__init__(scene, folder)
        if document:
            x, y, w, h = document["frame"]
            px, py, pw, ph = self.window[0] - 80, self.window[1], self.window[2] + 160, self.window[3] + 80
            if x * self.scale < px + pw and (x + w) * self.scale > px and y * self.scale < py + ph:
                raise SystemExit("The document window is under the popover, whose glass was recorded without it")
            self.document = {}
            for appearance, (pixels, icc, (left, top)) in document_pictures((w, h)).items():
                values = np.dstack([compose.to_display(pixels[..., :3], icc, self.display), pixels[..., 3:]])
                self.document[appearance] = (values, (round(x * self.scale) - left, round(y * self.scale) - top))

    def desktop_state(self, frame, region):
        desktop = super().desktop_state(frame, region)
        if not self.document:
            return desktop
        record = self.log["frames"][frame]
        appearance = record["desktop"]["menuBar"] if "desktop" in record else self.popover_state(frame)[0]
        values, (wx, wy) = self.document[appearance]
        x0, y0, x1, y1 = region
        ix0, iy0, ix1, iy1 = max(x0, wx), max(y0, wy), min(x1, wx + values.shape[1]), min(y1, wy + values.shape[0])
        if ix0 >= ix1 or iy0 >= iy1:
            return desktop
        desktop = np.array(desktop, np.float32)
        part = values[iy0 - wy:iy1 - wy, ix0 - wx:ix1 - wx]
        under = desktop[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0]
        desktop[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0] = part[..., :3] * part[..., 3:] + (1 - part[..., 3:]) * under
        return desktop


# --- The stills -----------------------------------------------------------------------------------

SCALE = 2  # a still is the video's size over this


def words(draw, spec, text, weight="Semibold", fill=(255, 255, 255), size=None, dy=0):
    """A line of words where a layout has them: its middle at "y", from "x" as "align" says"""
    size = (size or spec["size"]) / SCALE
    anchor = {"left": "lm", "centre": "mm", "right": "rm"}[spec.get("align", "left")]
    draw.text((spec["x"] / SCALE, spec["y"] / SCALE + dy), text, font=font(size, weight), fill=fill, anchor=anchor)
    return size


def still(board, recordings, layout_name, entry, label):
    """A still's picture, in sRGB: the recording's frame filmed by the layout's panes, and the words"""
    layout = board["layouts"][layout_name]
    width, height = (v // SCALE for v in layout["size"])
    if "picture" in entry:
        return np.asarray(Image.open(BUILD / entry["picture"]).convert("RGB").resize((width, height), Image.LANCZOS))
    key = (entry["recording"], entry.get("document", True))
    if key not in recordings:
        folder = BUILD / entry["recording"]
        recordings[key] = Recording(folder.name, folder, board.get("document") if key[1] else None)
    shot = recordings[key]
    cameras = []
    for name, pane in layout["panes"].items():
        view = entry.get("views", {}).get(name, pane)
        spec = {"size": [width, height], "keys": [{"at": 0, "centre": view["centre"], "height": view["height"]}]}
        cameras.append(compose.Camera(layout_name, spec, shot.stage.bounds, tuple(v // SCALE for v in pane["rect"])))
    values = pipeline.to_video(compose.film(shot, cameras, entry["frame"]), shot.display, "srgb", 8)
    image = Image.fromarray(values.astype(np.uint8), "RGB")
    draw = ImageDraw.Draw(image)
    label = entry.get("label", label)
    if label:
        spec = dict(layout["label"])
        if entry.get("icon"):
            # Safelight's icon before its name, as the end card has it (drawn by make-demo.sh --edit)
            side = round(spec["size"] * 1.5 / SCALE)
            icon = Image.open(BUILD / "edits" / "icon" / "icon.png").convert("RGBA").resize((side, side), Image.LANCZOS)
            image.paste(icon, (round(spec["x"] / SCALE - side * 0.1), round(spec["y"] / SCALE - side / 2)), icon)
            spec["x"] += side * SCALE * 0.95
        words(draw, spec, label)
    if entry.get("clock"):
        words(draw, layout["clock"], shot.log["frames"][entry["frame"]]["timeOfDay"][:5], "Bold")
    if caption := entry.get("caption"):
        lines = [caption] if isinstance(caption, str) else caption
        spec = layout["caption"]
        line_h = spec["size"] * 1.22 / SCALE
        small_h = spec["size"] * 0.66 * 1.3 / SCALE if entry.get("small") else 0
        top = -(line_h * len(lines) + small_h) / 2
        for n, line in enumerate(lines):
            words(draw, spec, line, dy=top + line_h * (n + 0.5))
        if entry.get("small"):
            words(draw, spec, entry["small"], "Medium", (176, 176, 186), spec["size"] * 0.66, dy=top + line_h * len(lines) + small_h * 0.5)
    return np.asarray(image)


# --- The sheet ------------------------------------------------------------------------------------

def wrap(draw, text, face, width):
    lines = []
    for paragraph in text.split("\n"):
        line = ""
        for word in paragraph.split():
            if line and draw.textlength(f"{line} {word}", font=face) > width:
                lines.append(line)
                line = word
            else:
                line = f"{line} {word}".strip()
        lines.append(line)
    return lines


def sheet(board, shots):
    """Every shot down the sheet: what it is on the left, its stills beside it, two in a row (three, of the
    tall ones), each with its frame and how the re-made shot will differ"""
    text_w, gap, pad, wide = 560, 28, 48, 900
    width = pad + text_w + gap + 2 * wide + gap + pad
    probe = ImageDraw.Draw(Image.new("RGB", (8, 8)))
    title, body, small, bold = font(52, "Bold"), font(26, "Regular"), font(21, "Regular"), font(30, "Semibold")
    rows = []
    for shot, pictures in shots:
        placed, x, y, row_h = [], 0, 0, 0
        for entry, picture in pictures:
            tall = picture.shape[0] > picture.shape[1]
            w = round(wide * 0.5) if tall else wide
            h = round(w * picture.shape[0] / picture.shape[1])
            if x + w > 2 * wide + gap:
                x, y, row_h = 0, y + row_h + gap, 0
            note = wrap(probe, entry.get("sheet", ""), small, w)
            placed.append((picture, x, y, w, h, note))
            x += w + gap
            row_h = max(row_h, h + 10 + 28 * len(note))
        text = [(bold, (255, 255, 255), f"{shot['name']}")]
        if "from" in shot:
            text.append((body, (255, 190, 90), f"{shot['from']:g}–{shot['to']:g} s  ·  {shot['to'] - shot['from']:g} s"))
        for line in wrap(probe, shot.get("what", ""), body, text_w):
            text.append((body, (214, 214, 220), line))
        rows.append((text, placed, max(y + row_h, sum(40 if f is bold else 34 for f, _, _ in text))))
    head = wrap(probe, board["about"], body, width - 2 * pad)
    top = pad + 76 + 34 * len(head) + 30
    image = Image.new("RGB", (width, top + sum(h + 56 for _, _, h in rows) + pad), (22, 22, 24))
    draw = ImageDraw.Draw(image)
    draw.text((pad, pad), board["title"], font=title, fill=(255, 255, 255))
    for n, line in enumerate(head):
        draw.text((pad, pad + 76 + 34 * n), line, font=body, fill=(190, 190, 198))
    y = top
    for text, placed, h in rows:
        draw.line((pad, y, width - pad, y), fill=(70, 70, 76), width=2)
        y += 28
        ty = y
        for face, fill, line in text:
            draw.text((pad, ty), line, font=face, fill=fill)
            ty += 40 if face is bold else 34
        for picture, px, py, w, ph, note in placed:
            small_picture = Image.fromarray(picture).resize((w, ph), Image.LANCZOS)
            image.paste(small_picture, (pad + text_w + gap + px, y + py))
            for n, line in enumerate(note):
                draw.text((pad + text_w + gap + px, y + py + ph + 8 + 28 * n), line, font=small, fill=(150, 150, 160))
        y += h + 28
    return image


def main():
    parser = argparse.ArgumentParser(description="Makes a storyboard's stills and its sheet.")
    parser.add_argument("storyboard", nargs="?", default="reshoot")
    args = parser.parse_args()
    board = json.loads((BOARDS / f"{args.storyboard}.json").read_text())
    out = OUT / args.storyboard
    out.mkdir(parents=True, exist_ok=True)
    recordings, shots = {}, []
    for number, shot in enumerate(board["shots"], 1):
        pictures = []
        for k, entry in enumerate(shot["stills"], 1):
            layout = entry.get("layout", "16:9")
            picture = still(board, recordings, layout, entry, shot.get("label"))
            name = f"{number}-{k}-{layout.replace(':', 'x')}.png"
            Image.fromarray(picture).save(out / name)
            source = f"{entry['recording']} frame {entry['frame']}" if "recording" in entry else entry["picture"]
            entry["sheet"] = f"{name}  ·  {source}" + (f"\n{entry['note']}" if entry.get("note") else "")
            pictures.append((entry, picture))
            print(f"{name}: {source}", flush=True)
        shots.append((shot, pictures))
    sheet(board, shots).save(OUT / f"{args.storyboard}.png")
    print(OUT / f"{args.storyboard}.png")


if __name__ == "__main__":
    main()
