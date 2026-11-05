# diff.py <system-settings.png> <safelight.png> <out.png>: compares two captures of the sheet at 2x from
# their grouped box down (their tops differ, as Safelight's has a picture for Light and one for Dark where
# System Settings has one): the share of pixels within so many levels, and the bands of rows that differ
# (y from the box's top, in pixels, with how many pixels in the row). The box's top is found as the first
# row 60 px in where the colour changes by more than 3 levels, below the pictures. Corners where System Settings' capture shows
# the window behind its sheet differ in the last rows.
import sys
from PIL import Image, ImageChops

def box_top(image, start):
    column = [image.getpixel((60, y)) for y in range(start, image.height)]
    return next(start + i for i in range(1, len(column)) if max(abs(p - q) for p, q in zip(column[i], column[i - 1])) > 3)

a, b = Image.open(sys.argv[1]).convert('RGB'), Image.open(sys.argv[2]).convert('RGB')
ta, tb = box_top(a, 220) - 1, box_top(b, 250) - 1
height = min(a.height - ta, b.height - tb)
difference = ImageChops.difference(a.crop((0, ta, a.width, ta + height)), b.crop((0, tb, b.width, tb + height))).convert('L')
pixels = list(difference.getdata())
for levels in (0, 2, 8, 32):
    print('within %2d levels: %.2f%%' % (levels, 100 * sum(p <= levels for p in pixels) / len(pixels)))
bands = []
for y in range(height):
    count = sum(p > 32 for p in pixels[y * difference.width:(y + 1) * difference.width])
    if count > 3:
        if bands and bands[-1][1] == y - 1:
            bands[-1][1], bands[-1][2] = y, max(bands[-1][2], count)
        else:
            bands.append([y, y, count])
print('bands that differ:', [tuple(band) for band in bands])
difference.point(lambda p: min(255, p * 4)).save(sys.argv[3])
