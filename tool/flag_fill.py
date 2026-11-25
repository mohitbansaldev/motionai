#!/usr/bin/env python3
"""win-30: a country filled with its flag (clipped to its borders, light relief shading) for map plates.
Usage: flag_fill.py flag.png relief.tif world_countries.json out.png A3 lon0 lat0 lon1 lat1 W H"""
import json, sys
from PIL import Image, ImageChops, ImageDraw, ImageOps
Image.MAX_IMAGE_PIXELS = None
flag_p, tif, cjson, out, a3 = sys.argv[1:6]
lon0, lat0, lon1, lat1 = map(float, sys.argv[6:10]); W, H = int(sys.argv[10]), int(sys.argv[11])
src = Image.open(tif); s = src.width / 360.0
rel = src.crop((int((lon0 + 180) * s), int((90 - lat1) * s), int((lon1 + 180) * s), int((90 - lat0) * s))).convert('L').resize((W, H), Image.LANCZOS)
rel = ImageOps.autocontrast(rel, cutoff=1)
c = next(c for c in json.load(open(cjson)) if c['a3'] == a3)
px = lambda lon, lat: ((lon - lon0) / (lon1 - lon0) * W, (lat1 - lat) / (lat1 - lat0) * H)
k = 2; m = Image.new('L', (W * k, H * k), 0); d = ImageDraw.Draw(m); xs = []; ys = []
for r in c['r']:
    pts = [px(r[i], r[i + 1]) for i in range(0, len(r) - 1, 2)]
    xs += [p[0] for p in pts]; ys += [p[1] for p in pts]
    if len(pts) > 2: d.polygon([(x * k, y * k) for x, y in pts], fill=255)
m = m.resize((W, H), Image.LANCZOS)
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
flag = Image.open(flag_p).convert('RGB')
bw, bh = x1 - x0, y1 - y0
sc = max(bw / flag.width, bh / flag.height) * 1.04
fw, fh = int(flag.width * sc), int(flag.height * sc)
canvas = Image.new('RGB', (W, H), (0, 0, 0))
canvas.paste(flag.resize((fw, fh), Image.LANCZOS), (int((x0 + x1) / 2 - fw / 2), int((y0 + y1) / 2 - fh / 2)))
shade = Image.merge('RGB', [rel.point(lambda v: int(150 + 105 * v / 255))] * 3)
img = ImageChops.multiply(canvas, shade).convert('RGBA'); img.putalpha(m); img.save(out)
print('bbox', [round(v) for v in (x0, y0, x1, y1)])
