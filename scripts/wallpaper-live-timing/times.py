# times.py <app.txt> <agent.txt>: for each wallpaper the live timing app picked, how long Safelight took
# to make it and ask macOS for it, and how long after the pick WallpaperAgent had its picture for each
# display ("Acquire Wallpaper" ended, after which it draws it), from the app's log and the agent's
import re
import sys


def seconds(clock):
    h, m, s = clock.split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)


displays, picks, sets = {}, [], []
for line in open(sys.argv[1]):
    parts = line.rstrip('\n').split('  ')
    if len(parts) < 2 or not re.match(r'\d\d:\d\d:\d\d\.\d\d\d$', parts[0]):
        continue
    time, kind = seconds(parts[0]), parts[1]
    if kind == 'display':
        displays[parts[2]] = parts[3]
    elif kind == 'pick':
        picks.append((time, parts[2], parts[3]))
    elif kind == 'set':
        sets.append((time, parts[2], parts[3]))
    elif kind == 'space':
        sets.append((time, parts[2], 'a Space'))
    elif kind in ('Show on all Spaces on', 'end'):
        picks.append((time, kind, ''))

# The agent's: each picture it asks its image extension for, by the display it's for, and each request
# of an app's it takes up
acquired, updates = [], []
creating, asked = None, {}
for line in open(sys.argv[2], errors='replace'):
    match = re.match(r'\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d\.\d\d\d) ', line)
    if not match:
        continue
    time = seconds(match.group(1))
    if "Enqueue: 'legacyContentUpdate'" in line:
        updates.append(time)
    created = re.search(r'Create new wallpaper in runtime: .*display: ([0-9A-F]{8})', line)
    if created:
        creating = created.group(1)
    acquire = re.search(r'([0-9A-F]{8}): (BEGIN|END) - \[com\.apple\.wallpaper\.extension\.image\] Wallpaper Timeline: Acquire Wallpaper', line)
    if acquire and acquire.group(2) == 'BEGIN':
        asked[acquire.group(1)] = creating
    elif acquire and acquire.group(1) in asked:
        acquired.append((time, asked.pop(acquire.group(1))))

for index, (time, label, what) in enumerate(picks):
    if label == 'end':
        break
    until = picks[index + 1][0]
    print(f'{label}  {what}')
    mine = [s for s in sets if time <= s[0] < until]
    shown = [s for s in mine if s[2] == 'shown Space']
    everywhere = [s for s in mine if s[2] == 'all Spaces']
    for s in shown:
        print(f'  {s[0] - time:6.2f} s  asked for on {displays.get(s[1], s[1])}, the Space shown')
    if everywhere:
        print(f'  {everywhere[0][0] - time:6.2f} s  asked for on every Space of {len(everywhere)} display(s)')
    spaces = [s for s in mine if s[2] == 'a Space']
    if spaces:
        print(f'  {spaces[0][0] - time:6.2f} s  to {spaces[-1][0] - time:.2f} s  asked for on {len(spaces)} other Spaces, one by one')
    for when, display in acquired:
        if time <= when < until:
            print(f'  {when - time:6.2f} s  the agent has its picture for {displays.get(display, display)}')
    mine = [u for u in updates if time <= u < until]
    if mine:
        print(f'  {len(mine)} requests taken up by the agent, from {mine[0] - time:.2f} s to {mine[-1] - time:.2f} s')
