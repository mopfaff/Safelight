#!/usr/bin/env python3
# Writes the Schedule that Safelight has on this Mac now to scripts/screenshots/my-schedule.json, as the
# demo's scenes write a schedule: a keyframe a line, with its time, color filter, intensity, tint,
# brightness and appearance. scripts/screenshots.sh draws the Schedule window with it (SCHEDULE=…), and
# scripts/make-reddit-pictures.py the desktop through a day on it, for the -my-schedule pictures.
#
#   scripts/export-schedule.py [file]
#
# It's read from Safelight's saved settings, so the app needn't be running. With "Adjust independently"
# on, each display has a brightness of its own in every keyframe, and the file gets the main display's:
# the pictures show one desktop, the main display's, with one Brightness column. A schedule set to
# Sunrise and Sunset has no times of its own to write, so it isn't taken.
#
# Needs PyObjC (for the main display's name among the saved ones).
import json, os, plistlib, subprocess, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "scripts", "screenshots", "my-schedule.json")

saved = plistlib.loads(subprocess.run(["defaults", "export", "Mo.Safelight", "-"], capture_output=True, check=True).stdout)
if "schedule" not in saved:
    sys.exit("Safelight has no schedule of your own saved: it's on its default one")
if saved.get("scheduleFollowsSun"):
    sys.exit("The Schedule is set to Sunrise and Sunset, so its keyframes have no times of their own; set it to Time of Day")

display = None
if saved.get("adjustsDisplaysIndependently"):
    # A display is saved by its UUID, as Safelight's Display.key has it
    import ctypes, objc, Quartz
    from CoreFoundation import CFUUIDCreateString
    colorsync = ctypes.CDLL("/System/Library/Frameworks/ColorSync.framework/ColorSync")
    colorsync.CGDisplayCreateUUIDFromDisplayID.restype = ctypes.c_void_p
    colorsync.CGDisplayCreateUUIDFromDisplayID.argtypes = [ctypes.c_uint32]
    display = str(CFUUIDCreateString(None, objc.objc_object(c_void_p=colorsync.CGDisplayCreateUUIDFromDisplayID(Quartz.CGMainDisplayID()))))
    if not any(display in keyframe.get("displayBrightness", {}) for keyframe in json.loads(saved["schedule"])):
        sys.exit(f"No keyframe has a brightness for the main display ({display})")

rows = []
for keyframe in sorted(json.loads(saved["schedule"]), key=lambda keyframe: keyframe["minute"]):
    brightness = keyframe.get("displayBrightness", {}).get(display, keyframe["brightness"])
    rows.append({"time": f"{keyframe['minute'] // 60:02}:{keyframe['minute'] % 60:02}", "colorFilter": keyframe["isColorFilterOn"],
                 "intensity": keyframe["intensity"], "tint": keyframe["tint"], "brightness": brightness,
                 # As Safelight reads one saved before keyframes had an appearance: Dark where the filter is on
                 "appearance": "dark" if keyframe.get("isDarkAppearance", keyframe["isColorFilterOn"]) else "light"})

with open(path, "w") as file:
    file.write("[\n" + ",\n".join("  " + json.dumps(row) for row in rows) + "\n]\n")
print(f"Wrote {len(rows)} keyframes to {os.path.relpath(path, os.getcwd())}"
      + (", with the main display's brightness" if display else ""))
