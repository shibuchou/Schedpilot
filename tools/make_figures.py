#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Draw the formal-5 result charts with Pillow.

matplotlib is not available here, so the charts are drawn directly.
Two narrow canvases (880 px) are used on purpose: the manual embeds figures at
~15.8 cm width, so a narrower bitmap makes the on-page text *larger*.

Data: evidence/sp4-vm/formal-5/ (medians), commit 65c4485, A/D x 20 x 60s.
"""
import os
from PIL import Image, ImageDraw, ImageFont

FIGDIR = r"D:\code\Ubuntu\schedpilot\docs\assets\diagrams"
REG = r"C:\Windows\Fonts\msyh.ttc"
BOLD = r"C:\Windows\Fonts\msyhbd.ttc"

W, H = 880, 560
INK = "#22303C"
GRID = "#E3E8ED"
A_COL = "#93A9C4"
D_COL = "#3F8F63"
RED = "#B04A4A"

f = lambda size, bold=False: ImageFont.truetype(BOLD if bold else REG, size)


def canvas():
    img = Image.new("RGB", (W, H), "#FFFFFF")
    return img, ImageDraw.Draw(img)


def txt(d, xy, s, size=20, bold=False, fill=INK, anchor="la"):
    d.text(xy, s, font=f(size, bold), fill=fill, anchor=anchor)


def bar(d, x0, y0, x1, y1, col, radius=5):
    d.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=col)


# ==================== fig6_qps.png ====================
d_img, d = canvas()
txt(d, (W // 2, 16), "吞吐：QPS（越高越好）", size=26, bold=True, anchor="ma")
txt(d, (W // 2, 52), "同一台机器、同一负载、同一干扰，只替换调度器", size=16, fill="#5A6B7A", anchor="ma")

PX0, PX1, PY0, PY1 = 92, 845, 130, 462
YMAX = 55000
for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
    y = PY1 - frac * (PY1 - PY0)
    d.line([PX0, y, PX1, y], fill=GRID, width=1)
    txt(d, (PX0 - 10, y), f"{int(YMAX*frac/1000)}k" if frac else "0", size=17, fill="#7A8794", anchor="rm")
d.line([PX0, PY0, PX0, PY1], fill="#B9C4CE", width=2)
d.line([PX0, PY1, PX1, PY1], fill="#B9C4CE", width=2)

bw = 132
for x, name, val, col in ((200, "A  系统默认", 17349.40, A_COL), (500, "D  SchedPilot", 49243.86, D_COL)):
    h = (val / YMAX) * (PY1 - PY0)
    bar(d, x, PY1 - h, x + bw, PY1, col)
    txt(d, (x + bw / 2, PY1 - h - 30), f"{val:,.0f}", size=24, bold=True, anchor="ma", fill=col)
    txt(d, (x + bw / 2, PY1 + 14), name, size=19, anchor="ma")

txt(d, (416, PY0 - 26), "+183.8%", size=30, bold=True, fill=RED, anchor="ma")
txt(d, (416, PY0 + 12), "逐轮配对 +181.5%", size=16, fill=RED, anchor="ma")
txt(d, (416, PY0 + 34), "20/20 轮更高", size=16, fill=RED, anchor="ma")
txt(d, (W // 2, H - 46), "A 臂下 Redis 只拿到约 17% 的 CPU 时间且从不迁移；D 臂给到 52%",
    size=16, fill="#44525F", anchor="ma")
txt(d, (W // 2, H - 22), "数据：evidence/sp4-vm/formal-5/（逐轮配对复算）",
    size=14, fill="#8492A0", anchor="ma")
d_img.save(os.path.join(FIGDIR, "fig6_qps.png"))

# ==================== fig7_latency.png ====================
d_img, d = canvas()
txt(d, (W // 2, 16), "延迟：毫秒（越低越好）", size=26, bold=True, anchor="ma")
txt(d, (W // 2, 52), "p50 降 7.6 倍；尾延迟 p99 降三成", size=16, fill="#5A6B7A", anchor="ma")

RX0, RX1, RY0, RY1 = 92, 845, 130, 462
LMAX = 5.0
for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
    y = RY1 - frac * (RY1 - RY0)
    d.line([RX0, y, RX1, y], fill=GRID, width=1)
    txt(d, (RX0 - 10, y), f"{LMAX*frac:.1f}", size=17, fill="#7A8794", anchor="rm")
d.line([RX0, RY0, RX0, RY1], fill="#B9C4CE", width=2)
d.line([RX0, RY1, RX1, RY1], fill="#B9C4CE", width=2)

for x, name, av, dv, delta in ((120, "p50", 3.355, 0.439, "−86.9%"),
                               (400, "p95", 4.151, 2.195, "−46.9%"),
                               (680, "p99", 4.439, 2.899, "−34.8%")):
    ha = (av / LMAX) * (RY1 - RY0)
    hd = (dv / LMAX) * (RY1 - RY0)
    bar(d, x, RY1 - ha, x + 74, RY1, A_COL)
    bar(d, x + 84, RY1 - hd, x + 158, RY1, D_COL)
    txt(d, (x + 37, RY1 - ha - 24), f"{av:.2f}", size=17, anchor="ma", fill=A_COL)
    txt(d, (x + 121, RY1 - hd - 24), f"{dv:.2f}", size=17, anchor="ma", fill=D_COL)
    txt(d, (x + 79, RY1 + 14), name, size=21, bold=True, anchor="ma")
    txt(d, (x + 79, RY1 + 42), delta, size=20, bold=True, fill=RED, anchor="ma")

lx, ly = 120, 96
d.rectangle([lx, ly, lx + 22, ly + 15], fill=A_COL)
txt(d, (lx + 30, ly - 3), "A 系统默认", size=17)
d.rectangle([lx + 200, ly, lx + 222, ly + 15], fill=D_COL)
txt(d, (lx + 230, ly - 3), "D SchedPilot", size=17)
txt(d, (W // 2, H - 22), "数据：evidence/sp4-vm/formal-5/per_run.csv（中位数与逐轮配对复算）",
    size=14, fill="#8492A0", anchor="ma")
d_img.save(os.path.join(FIGDIR, "fig7_latency.png"))

for n in ("fig6_qps.png", "fig7_latency.png"):
    p = os.path.join(FIGDIR, n)
    print("wrote", p, os.path.getsize(p), "bytes")
