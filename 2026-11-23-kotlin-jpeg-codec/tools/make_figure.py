#!/usr/bin/env python3
"""Builds screenshot.png from images that ochre itself encoded and decoded.
usage: tools/make_figure.py <dir with scanNN.png and qN.jpg/qN.png> <progressive.jpg> <out.png>"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

d, prog, out = sys.argv[1:4]
F = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FB = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
title, h2, small = ImageFont.truetype(FB, 30), ImageFont.truetype(FB, 19), ImageFont.truetype(F, 16)

data = open(prog, "rb").read()
# byte offset at which each scan's entropy data ends (= next marker after each SOS)
ends, i = [], 2
while i < len(data) - 1:
    if data[i] == 0xFF and data[i + 1] == 0xDA:
        j = i + 2 + (data[i + 2] << 8 | data[i + 3])
        while not (data[j] == 0xFF and data[j + 1] not in (0,) and not 0xD0 <= data[j + 1] <= 0xD7):
            j += 1
        ends.append(j); i = j
    else:
        i += 1

W, pad = 1640, 24
tw = (W - pad * 6) // 5; th = tw * 540 // 960
img = Image.new("RGB", (W, 1040), (246, 244, 239))
dr = ImageDraw.Draw(img)
dr.text((pad, 18), "ochre — a JPEG codec written from scratch in Kotlin", font=title, fill=(30, 30, 30))
dr.text((pad, 60), "baseline + progressive, encoder + decoder; output is bit-for-bit identical to libjpeg-turbo", font=small, fill=(90, 90, 90))

y = 104
dr.text((pad, y), "Progressive decoding — one ochre-encoded file rendered after scans 1, 2, 4, 6 and 10 of 10", font=h2, fill=(40, 40, 40))
y += 34
for k, sc in enumerate([1, 2, 4, 6, 10]):
    t = Image.open(os.path.join(d, f"scan{sc:02d}.png")).resize((tw, th), Image.LANCZOS)
    x = pad + k * (tw + pad)
    img.paste(t, (x, y))
    dr.text((x, y + th + 6), f"after scan {sc}: {ends[sc-1]/1024:.0f} KB ({100*ends[sc-1]/len(data):.0f}% of file)", font=small, fill=(60, 60, 60))
y += th + 50

dr.text((pad, y), "Quality ladder — 2x zoom of the same 150x84 region (ochre encoder, optimized Huffman tables)", font=h2, fill=(40, 40, 40))
y += 34
src = Image.open(os.path.join(d, "..", "src.png")) if os.path.exists(os.path.join(d, "..", "src.png")) else None
qs = [("orig", None), (3, None), (10, None), (30, None), (90, None)]
box = (520, 300, 670, 384)
zw = tw; zh = zw * 84 // 150
for k, (q, _) in enumerate(qs):
    p = os.path.join(d, "orig.png" if q == "orig" else f"q{q}.png")
    t = Image.open(p).convert("RGB").crop(box).resize((zw, zh), Image.NEAREST)
    x = pad + k * (tw + pad)
    img.paste(t, (x, y))
    if q == "orig":
        cap = "source (lossless)"
    else:
        size = os.path.getsize(os.path.join(d, f"q{q}.jpg"))
        cap = f"q={q}: {size/1024:.1f} KB, PSNR {open(os.path.join(d, f'q{q}.psnr')).read().strip()} dB"
    dr.text((x, y + zh + 6), cap, font=small, fill=(60, 60, 60))
y += zh + 50

dr.text((pad, y), "Differential testing against libjpeg-turbo (Pillow)", font=h2, fill=(40, 40, 40))
y += 32
for line in open(os.path.join(d, "fuzz.txt")).read().strip().splitlines():
    dr.text((pad, y), line, font=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 16), fill=(30, 30, 30)); y += 22
img = img.crop((0, 0, W, y + 16))
img.save(out)
print("wrote", out, img.size)
