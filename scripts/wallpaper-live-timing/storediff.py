# storediff.py <a> <b> [all] [--ignore-dates]: what changed between two stores, by owner (all Spaces, defaults,
# each display, each Space's displays), or with `all`, every owner; with --ignore-dates, not when each was set
import plistlib, sys
dates = '--ignore-dates' not in sys.argv
sys.argv = [a for a in sys.argv if a != '--ignore-dates']
def load(p):
    d = plistlib.load(open(p, 'rb')); out = {}
    def desc(owner):
        try:
            c = owner['Desktop']['Content']['Choices'][0]; conf = c.get('Configuration') or b''
            conf = plistlib.loads(conf) if conf else {}
            u = conf.get('url', {}).get('relative', '') if isinstance(conf, dict) else ''
            return c['Provider'].split('.')[-1] + ':' + u.split('/')[-3:] .__str__() + (' set ' + str(owner['Desktop'].get('LastSet'))[11:19] if dates else '')
        except Exception as e:
            return None
    out['AllSpacesAndDisplays'] = desc(d.get('AllSpacesAndDisplays', {}))
    out['SystemDefault'] = desc(d.get('SystemDefault', {}))
    for k, v in d.get('Displays', {}).items(): out['Display ' + k[:8]] = desc(v)
    for s, v in d.get('Spaces', {}).items():
        out['Space ' + s[:8] + ' Default'] = desc(v.get('Default', {}))
        for k, dv in v.get('Displays', {}).items(): out['Space ' + s[:8] + ' / ' + k[:8]] = desc(dv)
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k): print('  %-30s %s\n  %-30s -> %s' % (k, a.get(k), '', b.get(k)))
    elif len(sys.argv) > 3: print('  %-30s = %s' % (k, a.get(k)))
