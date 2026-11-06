# -*- coding: utf-8 -*-
"""生成 libranote 应用图标（零依赖 PIL）：
- assets/icon/app_icon.png          1024x1024 主图标（圆角蓝底 + 白色书本 + Z）
- assets/icon/app_icon_foreground.png  432x432 自适应图标前景（透明底，图形缩在安全区）
用法: python tool/make_icon.py
"""
from PIL import Image, ImageDraw, ImageFont
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "icon")
os.makedirs(OUT, exist_ok=True)

BG_TOP = (30, 58, 138)      # #1E3A8A
BG_BOTTOM = (14, 165, 233)  # #0EA5E9
COVER = (245, 248, 255)
COVER_EDGE = (203, 213, 225)
SPINE = (37, 99, 235)
TEXT_BAR = (148, 163, 184)
LETTER = (29, 78, 216)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw_book(draw, cx, cy, w, h, scale):
    """白色书本：封面圆角矩形 + 书脊 + 三条横线 + Z 字母。"""
    x0, y0 = cx - w / 2, cy - h / 2
    x1, y1 = cx + w / 2, cy + h / 2
    r = w * 0.08
    # 封面
    draw.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=COVER, outline=COVER_EDGE,
                           width=max(2, int(scale * 4)))
    # 书脊（左侧深色竖条，切成圆角）
    spine_w = w * 0.09
    spine = Image.new("RGBA", (int(w), int(h)), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spine)
    sd.rounded_rectangle([0, 0, spine_w, h], radius=r, fill=SPINE)
    draw.bitmap((int(x0), int(y0)), spine, fill=None)  # 直接贴，不裁剪
    # 三条标题横线
    bar_x0 = x0 + spine_w + w * 0.14
    bar_w = x1 - bar_x0 - w * 0.12
    bar_h = h * 0.045
    for i in range(3):
        by = y0 + h * (0.24 + i * 0.14)
        draw.rounded_rectangle([bar_x0, by, bar_x0 + bar_w, by + bar_h],
                               radius=bar_h / 2, fill=TEXT_BAR)
    # 大 Z 字母
    font_size = int(h * 0.42)
    font = None
    for p in (r"C:\Windows\Fonts\arialbd.ttf", r"C:\Windows\Fonts\segoeuib.ttf",
              r"C:\Windows\Fonts\msyhbd.ttc"):
        if os.path.exists(p):
            try:
                font = ImageFont.truetype(p, font_size)
                break
            except Exception:
                continue
    if font is None:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), "Z", font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text((cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]), "Z", font=font, fill=LETTER)


def rounded_gradient(size, radius, top, bottom):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # 垂直渐变
    grad = Image.new("RGBA", (size, size))
    px = grad.load()
    for y in range(size):
        c = lerp(top, bottom, y / size)
        for x in range(size):
            px[x, y] = (*c, 255)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)
    return img


def main():
    # 主图标 1024
    S = 1024
    img = rounded_gradient(S, int(S * 0.22), BG_TOP, BG_BOTTOM)
    draw = ImageDraw.Draw(img)
    draw_book(draw, S / 2, S / 2 + S * 0.02, S * 0.52, S * 0.62, 1.0)
    img.save(os.path.join(OUT, "app_icon.png"))
    print("saved app_icon.png")

    # 自适应前景 432（图形占中间 ~60% 安全区，透明底）
    F = 432
    fg = Image.new("RGBA", (F, F), (0, 0, 0, 0))
    d2 = ImageDraw.Draw(fg)
    draw_book(d2, F / 2, F / 2, F * 0.34, F * 0.42, F / 1024)
    fg.save(os.path.join(OUT, "app_icon_foreground.png"))
    print("saved app_icon_foreground.png")


if __name__ == "__main__":
    main()
