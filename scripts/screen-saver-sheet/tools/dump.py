# dump.py [store] [key]: the store with nested bplists decoded; key = Idle (default) / Desktop / all
import plistlib, sys, os, datetime
p = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != '-' else os.path.expanduser('~/Library/Application Support/com.apple.wallpaper/Store/Index.plist')
key = sys.argv[2] if len(sys.argv) > 2 else 'Idle'
def dec(v):
    if isinstance(v, bytes):
        if v.startswith(b'bplist'):
            try: return dec(plistlib.loads(v))
            except Exception: pass
        return v
    if isinstance(v, dict): return {k: dec(x) for k, x in v.items()}
    if isinstance(v, list): return [dec(x) for x in v]
    if isinstance(v, plistlib.UID): return 'UID(%d)' % v.data
    return v
def show(v, ind=0):
    pad = '  ' * ind
    if isinstance(v, dict):
        for k, x in v.items():
            if isinstance(x, (dict, list)) and x: print(pad + str(k) + ':'); show(x, ind + 1)
            else: print(pad + str(k) + ': ' + repr(x))
    elif isinstance(v, list):
        for i, x in enumerate(v):
            if isinstance(x, (dict, list)) and x: print(pad + '- [%d]' % i); show(x, ind + 1)
            else: print(pad + '- ' + repr(x))
    else: print(pad + repr(v))
d = dec(plistlib.load(open(p, 'rb')))
def owners(d):
    for k in ('AllSpacesAndDisplays', 'SystemDefault'):
        if k in d: yield k, d[k]
    for k, v in d.get('Displays', {}).items(): yield 'Display ' + k, v
    for s, v in d.get('Spaces', {}).items():
        if 'Default' in v: yield 'Space ' + s + ' Default', v['Default']
        for k, dv in v.get('Displays', {}).items(): yield 'Space ' + s + ' / ' + k, dv
if key == 'all': show(d)
else:
    for name, o in owners(d):
        if key in o: print('== ' + name); show(o[key], 1)
        else: print('== ' + name + ' (no ' + key + ')')
    extra = [k for k in d if k not in ('AllSpacesAndDisplays', 'SystemDefault', 'Displays', 'Spaces')]
    if extra: print('other top-level keys:', extra)
