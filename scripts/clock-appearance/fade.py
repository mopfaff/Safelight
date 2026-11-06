# fade.py <system-settings prefix> <safelight prefix>: compares how the lock screen fades in and out over
# the picture of the desktop, from the curves tools/film.swift wrote for each (<prefix>-open.csv and
# <prefix>-close.csv). Each curve is fitted with a critically damped spring, SwiftUI's
# .spring(response:dampingFraction: 1), for its response and for when it starts after the press or the
# close; the two are then compared from their starts, sample by sample.
import csv
import math
import sys


def read(path):
    with open(path) as f:
        return [(float(row['time']), float(row['lockscreen'])) for row in csv.DictReader(f)]


def spring(t, response):
    """How far a critically damped spring with this response has got after t seconds"""
    if t <= 0:
        return 0.0
    w = 2 * math.pi / response
    return 1 - (1 + w * t) * math.exp(-w * t)


def fit(points, closing):
    """The response and start that fit the points best, and the root mean square of what's left over"""
    best = None
    for r in range(200, 1001, 5):
        response = r / 1000
        for s in range(0, 301):
            start = s / 1000
            error = 0.0
            for t, v in points:
                p = spring(t - start, response)
                error += ((1 - p if closing else p) - v) ** 2
            if best is None or error < best[0]:
                best = (error, response, start)
    error, response, start = best
    return response, start, math.sqrt(error / len(points))


def at(points, start, t):
    """The curve's value t seconds after its start, between the frames on either side"""
    shifted = [(time - start, v) for time, v in points]
    for (t0, v0), (t1, v1) in zip(shifted, shifted[1:]):
        if t0 <= t <= t1:
            return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
    return None


for phase in ('open', 'close'):
    closing = phase == 'close'
    curves = {name: read(f'{prefix}-{phase}.csv') for name, prefix in (('System Settings', sys.argv[1]), ('Safelight', sys.argv[2]))}
    fits = {}
    for name, points in curves.items():
        response, start, rms = fit(points, closing)
        fits[name] = start
        print(f'{phase:5}  {name:15}  spring response {response:.3f} s, starts {start * 1000:.0f} ms after the '
              f'{"close" if closing else "press"}, off the spring by {rms:.3f} (RMS), {len(points)} frames')
    # The two curves against each other, from their own starts, every 1/60 s while either is moving
    differences = []
    for k in range(1, 60):
        t = k / 60
        a, b = (at(curves[n], fits[n], t) for n in ('System Settings', 'Safelight'))
        if a is not None and b is not None:
            differences.append(abs(a - b))
    if differences:
        print(f'{phase:5}  from their starts, Safelight is within {max(differences):.3f} of System Settings '
              f'(mean {sum(differences) / len(differences):.3f}) over {len(differences)} samples')
