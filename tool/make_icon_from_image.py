# -*- coding: utf-8 -*-
"""把用户提供的图片做成 App 全套图标（零依赖 PIL 之外）：
- assets/icon/app_icon.png            1024x1024 主图标（居中裁方 + 缩放）
- assets/icon/app_icon_foreground.png 432x432 自适应图标前景（整图铺满）
- windows/runner/resources/app_icon.ico  多尺寸 ICO（16~256）
用法: python tool/make_icon_from_image.py <source.png>
"""
import os
import sys

from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..")
ICON_DIR = os.path.join(ROOT, "assets", "icon")
ICO_PATH = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")


def square_crop(im):
    w, h = im.size
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    return im.crop((left, top, left + side, top + side))


def main():
    if len(sys.argv) < 2:
        print("usage: python tool/make_icon_from_image.py <source.png>")
        sys.exit(1)
    src = sys.argv[1]
    if not os.path.exists(src):
        print("source not found:", src)
        sys.exit(1)

    im = square_crop(Image.open(src).convert("RGBA"))
    os.makedirs(ICON_DIR, exist_ok=True)

    main_icon = im.resize((1024, 1024), Image.LANCZOS)
    main_icon.save(os.path.join(ICON_DIR, "app_icon.png"))
    print("saved assets/icon/app_icon.png", main_icon.size)

    fg = im.resize((432, 432), Image.LANCZOS)
    fg.save(os.path.join(ICON_DIR, "app_icon_foreground.png"))
    print("saved assets/icon/app_icon_foreground.png", fg.size)

    # Windows ICO（多尺寸；PIL 自动生成）——Runner.rc 与打包 exe 都用它。
    ico = im.resize((256, 256), Image.LANCZOS)
    ico.save(
        ICO_PATH,
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
               (128, 128), (256, 256)],
    )
    print("saved windows/runner/resources/app_icon.ico")


if __name__ == "__main__":
    main()
