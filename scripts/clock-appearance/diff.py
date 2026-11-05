# diff.py <system-settings.png> <safelight.png> <out.png>: compares two captures of the popover at 2x, each
# cut to the popover's window. The glass behind the controls takes its colours from what's under it, which
# differs a little between the two however alike the backdrop, so besides the share of pixels within so
# many levels, it reports how far each control lies from System Settings' (in pixels), matched by its
# edges, which the glass doesn't move. The captures' sizes must match.
import sys
import numpy as np
from PIL import Image, ImageChops

a, b = Image.open(sys.argv[1]).convert('RGB'), Image.open(sys.argv[2]).convert('RGB')
if a.size != b.size:
    print('sizes differ:', a.size, b.size)
    w, h = min(a.width, b.width), min(a.height, b.height)
    a, b = a.crop((0, 0, w, h)), b.crop((0, 0, w, h))
difference = ImageChops.difference(a, b).convert('L')
pixels = np.asarray(difference)
for levels in (0, 2, 8, 32):
    print('within %2d levels: %.2f%%' % (levels, 100 * (pixels <= levels).mean()))
difference.point(lambda p: min(255, p * 4)).save(sys.argv[3])

# Each control's region in the popover (2x pixels), and the shift of Safelight's that matches best
la, lb = (np.asarray(image.convert('L')).astype(float) for image in (a, b))
regions = {'Show large clock': (60, 65, 280, 105), 'its pop-up': (525, 65, 790, 105), 'Soft, ringed': (75, 140, 170, 240),
           'Rounded': (205, 150, 285, 225), 'Stencil': (330, 150, 410, 225), 'New York': (450, 150, 530, 225),
           'Slab': (575, 150, 655, 225), 'Weight': (60, 280, 160, 312), 'its slider': (390, 270, 800, 315),
           'first divider': (60, 110, 800, 135), 'grouped box': (40, 35, 820, 60)}

def edges(region):
    return np.abs(np.diff(region, axis=0))[:, :-1] + np.abs(np.diff(region, axis=1))[:-1, :]

for name, (x0, y0, x1, y1) in regions.items():
    ea = edges(la[y0:y1, x0:x1])
    error, dx, dy = min((np.mean(np.abs(ea - edges(lb[y0 + dy:y1 + dy, x0 + dx:x1 + dx]))), dx, dy)
                        for dy in range(-4, 5) for dx in range(-4, 5))
    print('%-17s off by dx=%+d dy=%+d px (edges then differ by %.1f levels)' % (name, dx, dy, error))
