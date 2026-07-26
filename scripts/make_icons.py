#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
纯 Python 生成 SunoHelper App 图标集（不依赖 Pillow / PIL）。
在 CI 或本地（Bash 可用时）运行：python3 scripts/make_icons.py
生成 Sources/SunoHelper/Assets.xcassets/AppIcon.appiconset/ 下的全套 PNG + Contents.json。
设计：珊瑚橙→品红竖向渐变 + 白色八分音符。
"""
import os
import zlib
import struct
import math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Sources", "SunoHelper", "Assets.xcassets", "AppIcon.appiconset")
SIZE = 1024

# 品牌渐变（上→下）
TOP = (255, 138, 61)      # #FF8A3D
BOTTOM = (255, 46, 99)    # #FF2E63
NOTE = (255, 255, 255)


class Img:
    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.buf = bytearray(w * h * 4)

    def set(self, x, y, r, g, b, a):
        i = (y * self.w + x) * 4
        # 预乘 alpha 混合（简单 over）
        if a >= 255:
            self.buf[i] = r
            self.buf[i + 1] = g
            self.buf[i + 2] = b
            self.buf[i + 3] = 255
        elif a > 0:
            ba = a / 255.0
            dr = self.buf[i] / 255.0
            dg = self.buf[i + 1] / 255.0
            db = self.buf[i + 2] / 255.0
            nr = r / 255.0
            ng = g / 255.0
            nb = b / 255.0
            out_r = nr * ba + dr * (1 - ba)
            out_g = ng * ba + dg * (1 - ba)
            out_b = nb * ba + db * (1 - ba)
            self.buf[i] = int(out_r * 255)
            self.buf[i + 1] = int(out_g * 255)
            self.buf[i + 2] = int(out_b * 255)
            self.buf[i + 3] = 255

    def get(self, x, y):
        i = (y * self.w + x) * 4
        return self.buf[i], self.buf[i + 1], self.buf[i + 2], self.buf[i + 3]


def lerp(a, b, t):
    return int(a + (b - a) * t)


def fill_background(img):
    for y in range(img.h):
        t = y / max(1, img.h - 1)
        r = lerp(TOP[0], BOTTOM[0], t)
        g = lerp(TOP[1], BOTTOM[1], t)
        b = lerp(TOP[2], BOTTOM[2], t)
        for x in range(img.w):
            img.set(x, y, r, g, b, 255)


def fill_ellipse(img, cx, cy, rx, ry, color):
    for y in range(img.h):
        for x in range(img.w):
            nx = (x - cx) / rx
            ny = (y - cy) / ry
            if nx * nx + ny * ny <= 1.0:
                img.set(x, y, *color, 255)


def fill_rect(img, x0, y0, x1, y1, color):
    for y in range(int(y0), int(y1)):
        for x in range(int(x0), int(x1)):
            if 0 <= x < img.w and 0 <= y < img.h:
                img.set(x, y, *color, 255)


def draw_note(img):
    cx, cy = int(SIZE * 0.42), int(SIZE * 0.60)
    rx, ry = int(SIZE * 0.13), int(SIZE * 0.10)
    # 符头（椭圆，略倾斜：用圆再压扁）
    fill_ellipse(img, cx, cy, rx, ry, NOTE)
    # 符干（符头右侧竖线向上）
    stem_x = cx + rx - int(SIZE * 0.02)
    stem_top = cy - int(SIZE * 0.36)
    fill_rect(img, stem_x, stem_top, stem_x + int(SIZE * 0.028), cy + int(SIZE * 0.02), NOTE)
    # 符尾（顶部旗状：用一系列矩形斜带近似）
    for i in range(int(SIZE * 0.20)):
        yy = stem_top + i
        xx0 = stem_x + int(SIZE * 0.028) + int(i * 0.55)
        xx1 = xx0 + max(6, int(SIZE * 0.02))
        fill_rect(img, xx0, yy, xx1, yy + 3, NOTE)


def downscale(src, tw, th):
    dst = Img(tw, th)
    sw, sh = src.w, src.h
    for dy in range(th):
        for dx in range(tw):
            sx0 = dx * sw // tw
            sx1 = max(sx0 + 1, (dx + 1) * sw // tw)
            sy0 = dy * sh // th
            sy1 = max(sy0 + 1, (dy + 1) * sh // th)
            r = g = b = 0
            n = 0
            for yy in range(sy0, sy1):
                for xx in range(sx0, sx1):
                    pr, pg, pb, _ = src.get(xx, yy)
                    r += pr
                    g += pg
                    b += pb
                    n += 1
            dst.set(dx, dy, r // n, g // n, b // n, 255)
    return dst


def encode_png(img):
    w, h = img.w, img.h
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r, g, b, a = img.get(x, y)
            raw += bytes((r, g, b, a))
    comp = zlib.compress(bytes(raw), 9)

    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", comp) + chunk(b"IEND", b""))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    base = Img(SIZE, SIZE)
    fill_background(base)
    draw_note(base)

    sizes = {
        "icon-40.png": 40,
        "icon-60.png": 60,
        "icon-58.png": 58,
        "icon-87.png": 87,
        "icon-80.png": 80,
        "icon-120.png": 120,
        "icon-180.png": 180,
        "icon-76.png": 76,
        "icon-152.png": 152,
        "icon-167.png": 167,
        "icon-1024.png": 1024,
    }
    for fname, px in sizes.items():
        im = base if px == SIZE else downscale(base, px, px)
        with open(os.path.join(OUT_DIR, fname), "wb") as f:
            f.write(encode_png(im))
        print("wrote", fname, px)

    # 写 Contents.json
    images = [
        {"idiom": "iphone", "scale": "2x", "size": "20x20", "filename": "icon-40.png"},
        {"idiom": "iphone", "scale": "3x", "size": "20x20", "filename": "icon-60.png"},
        {"idiom": "iphone", "scale": "2x", "size": "29x29", "filename": "icon-58.png"},
        {"idiom": "iphone", "scale": "3x", "size": "29x29", "filename": "icon-87.png"},
        {"idiom": "iphone", "scale": "2x", "size": "40x40", "filename": "icon-80.png"},
        {"idiom": "iphone", "scale": "3x", "size": "40x40", "filename": "icon-120.png"},
        {"idiom": "iphone", "scale": "2x", "size": "60x60", "filename": "icon-120.png"},
        {"idiom": "iphone", "scale": "3x", "size": "60x60", "filename": "icon-180.png"},
        {"idiom": "ipad", "scale": "1x", "size": "76x76", "filename": "icon-76.png"},
        {"idiom": "ipad", "scale": "2x", "size": "76x76", "filename": "icon-152.png"},
        {"idiom": "ipad", "scale": "2x", "size": "83.5x83.5", "filename": "icon-167.png"},
        {"idiom": "ios-marketing", "scale": "1x", "size": "1024x1024", "filename": "icon-1024.png"},
    ]
    import json
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(OUT_DIR, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump(contents, f, indent=2, ensure_ascii=False)
    print("✅ AppIcon.appiconset 生成完成")


if __name__ == "__main__":
    main()
