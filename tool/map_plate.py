#!/usr/bin/env python3
"""win-30: reference-style map plates from Natural Earth shaded relief.

Renders, for a lon/lat box, high-resolution layers that MotionAI animates:
  base.jpg          light relief land + dark relief ocean (graded like the reference)
  fill_<A3>.png     one country: its colour multiplied over the relief (RGBA)
  line_<A3>.png     that country's outline (thick, light)
  borders.png       every border, thin
Usage: map_plate.py relief.tif world_countries.json out_dir lon0 lat0 lon1 lat1 W H  A3=#hex ...
"""
import json, math, os, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

Image.MAX_IMAGE_PIXELS = None


def main():
    tif, cjson, out, lon0, lat0, lon1, lat1, W, H = sys.argv[1:10]
    lon0, lat0, lon1, lat1 = map(float, (lon0, lat0, lon1, lat1))
    W, H = int(W), int(H)
    fills = dict(a.split('=') for a in sys.argv[10:])
    os.makedirs(out, exist_ok=True)
    src = Image.open(tif)
    s = src.width / 360.0
    box = (int((lon0 + 180) * s), int((90 - lat1) * s), int(math.ceil((lon1 + 180) * s)), int(math.ceil((90 - lat0) * s)))
    rel = src.crop(box).convert('L').resize((W, H), Image.LANCZOS)
    countries = json.load(open(cjson))

    def px(lon, lat):
        return ((lon - lon0) / (lon1 - lon0) * W, (lat1 - lat) / (lat1 - lat0) * H)

    def rings(c):
        for r in c['r']:
            yield [px(r[i], r[i + 1]) for i in range(0, len(r) - 1, 2)]

    # Land mask from every country polygon (4x supersampled for clean edges).
    k = 2
    land = Image.new('L', (W * k, H * k), 0)
    d = ImageDraw.Draw(land)
    for c in countries:
        for r in rings(c):
            if len(r) > 2:
                d.polygon([(x * k, y * k) for x, y in r], fill=255)
    land = land.resize((W, H), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.6))

    # Grade: land light warm grey relief, ocean deep slate relief.
    r = ImageOps.autocontrast(rel, cutoff=1)
    land_rgb = Image.merge('RGB', [r.point(lambda v, a=a, b=b: int(a + (b - a) * v / 255)) for a, b in ((70, 222), (66, 212), (60, 196))])
    sea_rgb = Image.merge('RGB', [r.point(lambda v, a=a, b=b: int(a + (b - a) * v / 255)) for a, b in ((12, 40), (18, 50), (24, 62))])
    base = Image.composite(land_rgb, sea_rgb, land)
    # soft coastal glow on the sea side
    glow = land.filter(ImageFilter.GaussianBlur(W / 300))
    base = Image.composite(Image.blend(base, Image.new('RGB', (W, H), (90, 110, 120)), 0.25), base, ImageChops.subtract(glow, land))
    base.save(os.path.join(out, 'base.jpg'), quality=92)

    # All borders, thin and light.
    bl = Image.new('RGBA', (W * k, H * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(bl)
    lw = max(2, int(W / 900)) * k
    for c in countries:
        for rr in rings(c):
            if len(rr) > 2:
                d.line([(x * k, y * k) for x, y in rr] + [(rr[0][0] * k, rr[0][1] * k)], fill=(240, 232, 214, 150), width=lw, joint='curve')
    bl.resize((W, H), Image.LANCZOS).save(os.path.join(out, 'borders.png'))

    shade = Image.merge('RGB', [r.point(lambda v: int(105 + 150 * v / 255))] * 3)
    for a3, hexc in fills.items():
        c = next((c for c in countries if c['a3'] == a3 or c['n'].lower() == a3.lower()), None)
        if c is None:
            print('unknown', a3)
            continue
        m = Image.new('L', (W * k, H * k), 0)
        d = ImageDraw.Draw(m)
        for rr in rings(c):
            if len(rr) > 2:
                d.polygon([(x * k, y * k) for x, y in rr], fill=255)
        m = m.resize((W, H), Image.LANCZOS)
        col = tuple(int(hexc.lstrip('#')[i:i + 2], 16) for i in (0, 2, 4))
        tinted = ImageChops.multiply(Image.new('RGB', (W, H), col), shade)
        layer = tinted.convert('RGBA')
        layer.putalpha(m)
        layer.save(os.path.join(out, f'fill_{c["a3"]}.png'))
        ln = Image.new('RGBA', (W * k, H * k), (0, 0, 0, 0))
        d = ImageDraw.Draw(ln)
        for rr in rings(c):
            if len(rr) > 2:
                d.line([(x * k, y * k) for x, y in rr] + [(rr[0][0] * k, rr[0][1] * k)], fill=(255, 244, 220, 255), width=lw * 2, joint='curve')
        ln.resize((W, H), Image.LANCZOS).save(os.path.join(out, f'line_{c["a3"]}.png'))
        print('ok', c['n'], c['a3'])


if __name__ == '__main__':
    main()
