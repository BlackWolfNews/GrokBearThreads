#!/usr/bin/env python3 -I
"""Cut a generated sprite sheet (bears on a flat white background) into
separate transparent PNGs.

    cut-sprites.py sheet.png outdir name1 name2 ...

Uses sips to get a BMP (no PIL or ImageMagick on this Mac); the keying,
column split and PNG writing are plain Python. White becomes transparent with a soft edge so antialiased
outlines don't go jagged, then the sheet is split wherever a run of
columns is fully transparent.
"""
import glob, os, subprocess, sys, zlib, struct

sheet, outdir, *names = sys.argv[1:]
os.makedirs(outdir, exist_ok=True)
# sips (macOS) writes a 24-bit BMP, which is trivial to parse: 54-byte
# header, bottom-up rows of BGR padded to 4 bytes.
import tempfile
bmp = os.path.join(tempfile.mkdtemp(), 'sheet.bmp')
subprocess.run(['sips', '-s', 'format', 'bmp', sheet, '--out', bmp], check=True, capture_output=True)
data = open(bmp, 'rb').read()
off = struct.unpack_from('<I', data, 10)[0]
w, h = struct.unpack_from('<ii', data, 18)
topdown = h < 0   # a negative height means rows are stored top-down
h = abs(h)
bpp = struct.unpack_from('<H', data, 28)[0]
assert bpp in (24, 32), bpp
stride = ((w * bpp // 8) + 3) // 4 * 4
px = bytearray(w * h * 4)
step = bpp // 8
for y in range(h):
    src = off + (y if topdown else h - 1 - y) * stride
    dst = y * w * 4
    for x in range(w):
        b, g, r = data[src + x*step], data[src + x*step + 1], data[src + x*step + 2]
        px[dst + x*4] = r; px[dst + x*4 + 1] = g; px[dst + x*4 + 2] = b; px[dst + x*4 + 3] = 255

# key out white: alpha from how far the pixel is from pure white
LO, HI = 18, 90   # distance below LO -> transparent, above HI -> opaque
for i in range(0, len(px), 4):
    r, g, b = px[i], px[i+1], px[i+2]
    d = max(255 - r, 255 - g, 255 - b)
    if d <= LO:
        px[i+3] = 0
    elif d < HI:
        px[i+3] = int(255 * (d - LO) / (HI - LO))

# connected components of solid pixels (8-way), then group components
# whose x ranges mostly overlap (the z's above a sleeper) but not ones that
# only brush (a raised paw next to the sleeper). Each group is one sprite.
import sys as _sys
_sys.setrecursionlimit(10000)
solid = bytearray(w * h)
for i in range(w * h):
    solid[i] = 1 if px[i*4 + 3] > 40 else 0
label = [0] * (w * h)
comps = []  # (x0, x1, y0, y1, pixels)
for start in range(w * h):
    if solid[start] and not label[start]:
        cid = len(comps) + 1
        stack = [start]; label[start] = cid
        pts = []
        x0 = x1 = start % w; y0 = y1 = start // w
        while stack:
            i = stack.pop(); pts.append(i)
            x, y = i % w, i // w
            x0, x1, y0, y1 = min(x0, x), max(x1, x), min(y0, y), max(y1, y)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        j = ny * w + nx
                        if solid[j] and not label[j]:
                            label[j] = cid; stack.append(j)
        comps.append([x0, x1 + 1, y0, y1 + 1, pts])
comps = [c for c in comps if len(c[4]) > 60]
# union-find on x overlap
parent = list(range(len(comps)))
def find(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]; i = parent[i]
    return i
for i in range(len(comps)):
    for j in range(i + 1, len(comps)):
        a_, b_ = comps[i], comps[j]
        ov = min(a_[1], b_[1]) - max(a_[0], b_[0])
        if ov > 0.3 * min(a_[1] - a_[0], b_[1] - b_[0]):
            parent[find(i)] = find(j)
groups = {}
for i, c in enumerate(comps):
    groups.setdefault(find(i), []).append(c)
groups = sorted(groups.values(), key=lambda g: min(c[0] for c in g))
if len(groups) != len(names):
    print(f'found {len(groups)} sprites, expected {len(names)}', file=sys.stderr)
    names = names[:len(groups)] + [f'sprite{i}' for i in range(len(names), len(groups))]

def write_png(path, group):
    x0 = min(c[0] for c in group); x1 = max(c[1] for c in group)
    y0 = min(c[2] for c in group); y1 = max(c[3] for c in group)
    pad = 4
    x0, x1, y0, y1 = max(0, x0-pad), min(w, x1+pad), max(0, y0-pad), min(h, y1+pad)
    cw, ch = x1 - x0, y1 - y0
    keep = bytearray(w * h)
    for c in group:
        for i in c[4]:
            keep[i] = 1
    out = bytearray()
    for y in range(y0, y1):
        out += b'\x00'
        for x in range(x0, x1):
            i = y * w + x
            # keep the soft edge: pixels next to the group with partial alpha
            near = keep[i] or any(keep[(y+dy)*w + (x+dx)] for dy in (-1,0,1) for dx in (-1,0,1) if 0 <= x+dx < w and 0 <= y+dy < h)
            if near:
                out += bytes(px[i*4:i*4+4])
            else:
                out += b'\x00\x00\x00\x00'
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', cw, ch, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(out), 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)
    print(os.path.basename(path), f'{cw}x{ch}')

for group, name in zip(groups, names):
    write_png(os.path.join(outdir, name + '.png'), group)
