#!/usr/bin/env python3
"""
生成中性的应用截图（官网与 AltStore 列表共用）。

## 为什么是「画」而不是「截」

截真机屏幕需要跑一次 App（本项目本地没有 Xcode），而且真机截图会带上
**用户自己的内容**——把别人作品的书名、封面截进公开仓库，正是本项目
红线要避免的那类事（`tools/check_redlines.py` 会扫站点名，但它扫不了图片）。

所以这里用 Pillow 画三张**完全虚构**的界面示意：
虚构的书名（Sample Series A/B/C）、纯色封面块、示意用的对白文本。
既没有第三方内容，也不依赖任何字体是否安装了中文字形（正文一律英文）。

## 尺寸依据

AltStore 的 `screenshots` 字段要求图片能代表各机型；主流做法是给
6.7" 档的一张竖图（1290×2796）与 5.5" 档的一张（1242×2208）。
这里统一出 1290×2796 的三张（同一机型档位），AltStore 会自行缩放。

用法：python3 tools/make_screenshots.py
输出：website/assets/screenshots/*.png
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 1290, 2796
OUT_DIR = os.path.join("website", "assets", "screenshots")

# 虚构内容的配色（与 App 的强调色一致，避免"看起来不像同一个产品"）
ACCENT = (74, 63, 168)
INK = (28, 28, 34)
MUTED = (120, 120, 132)
PAPER = (255, 255, 255)
CARD = (244, 244, 248)

COVER_COLORS = [
    (196, 88, 96),
    (86, 132, 180),
    (150, 140, 90),
    (110, 150, 130),
    (140, 110, 170),
    (200, 150, 100),
]

SERIES = ["Sample Series A", "Sample Series B", "Sample Series C", "Sample Series D"]
CHAPTERS = ["Chapter 01", "Chapter 02", "Chapter 03", "Chapter 04", "Chapter 05"]


def font(size, bold=False):
    """尽量取一个好看的字体；取不到就退回 Pillow 自带位图字体（仍然可用）。"""
    candidates = [
        r"C:\Windows\Fonts\segoeuib.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def status_bar(draw):
    """顶部状态栏：时间 + 信号/电量的示意块（不画真实系统图标，避免商标问题）。"""
    draw.rectangle([0, 0, WIDTH, 120], fill=PAPER)
    draw.text((60, 48), "9:41", font=font(48, bold=True), fill=INK)
    draw.rounded_rectangle([WIDTH - 250, 62, WIDTH - 60, 88], radius=13, fill=MUTED)
    draw.rounded_rectangle([WIDTH - 250, 62, WIDTH - 150, 88], radius=13, fill=INK)


def nav_bar(draw, title, left_glyph="<"):
    draw.rectangle([0, 120, WIDTH, 260], fill=PAPER)
    draw.text((60, 160), left_glyph, font=font(64, bold=True), fill=ACCENT)
    draw.text((WIDTH // 2, 168), title, font=font(52, bold=True), fill=INK, anchor="ma")
    draw.line([0, 258, WIDTH, 258], fill=(226, 226, 232), width=2)


def sentence(draw, x, y, width, size, color, lines=1, bold=False):
    """画几条「文字」占位条：比假英文更像真截图，也不会被误读成真实文案。"""
    spacing = int(size * 1.8)
    height = int(size * 1.1)
    for index in range(lines):
        # 最后一行短一点，看起来像自然断行的段落
        line_width = width if index < lines - 1 else int(width * 0.62)
        top = y + index * spacing
        draw.rounded_rectangle(
            [x, top, x + line_width, top + height],
            radius=int(height / 2),
            fill=color,
        )
    _ = bold


def screen_library():
    image = Image.new("RGB", (WIDTH, HEIGHT), PAPER)
    draw = ImageDraw.Draw(image)
    status_bar(draw)
    nav_bar(draw, "Library")

    # 两列封面网格
    margin, gap = 60, 40
    column_width = (WIDTH - margin * 2 - gap) // 2
    cover_height = int(column_width * 1.42)
    for index, series in enumerate(SERIES):
        row, column = divmod(index, 2)
        x = margin + column * (column_width + gap)
        y = 320 + row * (cover_height + 170)
        draw.rounded_rectangle([x, y, x + column_width, y + cover_height], radius=18,
                               fill=COVER_COLORS[index % len(COVER_COLORS)])
        draw.text((x + 24, y + 24), series[0], font=font(120, bold=True),
                  fill=(255, 255, 255))
        draw.text((x, y + cover_height + 24), series, font=font(42, bold=True), fill=INK)
        draw.text((x, y + cover_height + 84), "Chapter 03 · page 12",
                  font=font(34), fill=MUTED)

    # 未读角标
    draw.ellipse([WIDTH - margin - 90, 300, WIDTH - margin + 20, 410], fill=ACCENT)
    draw.text((WIDTH - margin - 35, 330), "3", font=font(56, bold=True),
              fill=PAPER, anchor="ma")
    return image


def screen_reader():
    """阅读器 + 翻译浮层：演示"原文被译文替换"的效果。"""
    image = Image.new("RGB", (WIDTH, HEIGHT), (34, 32, 30))
    draw = ImageDraw.Draw(image)

    # 页图：一块浅色纸面 + 两个分格
    page = [100, 260, WIDTH - 100, HEIGHT - 500]
    draw.rounded_rectangle(page, radius=12, fill=(248, 246, 240))
    split = (page[0] + page[2]) // 2
    draw.line([split, page[1], split, page[3]], fill=(210, 206, 198), width=6)

    # 左右各一个对白气泡：气泡里是"译文条"（示意排版回填）
    for index, box in enumerate([
        [page[0] + 50, page[1] + 90, split - 40, page[1] + 430],
        [split + 40, page[3] - 470, page[2] - 50, page[3] - 130],
    ]):
        draw.rounded_rectangle(box, radius=28, fill=PAPER, outline=(206, 202, 194), width=4)
        inner_x = box[0] + 40
        inner_width = box[2] - box[0] - 80
        sentence(draw, inner_x, box[1] + 50, inner_width, 34, (60, 58, 66), lines=3)
        # 原文小字提示（对应"额外标注原文"设置）
        draw.rounded_rectangle([inner_x, box[3] - 90, inner_x + int(inner_width * 0.5), box[3] - 62],
                               radius=12, fill=(206, 202, 194))
        _ = index

    # 顶栏：翻译按钮高亮
    draw.rectangle([0, 120, WIDTH, 250], fill=(34, 32, 30))
    draw.text((60, 160), "<", font=font(64, bold=True), fill=(235, 232, 228))
    draw.rounded_rectangle([WIDTH - 300, 150, WIDTH - 60, 240], radius=18, fill=ACCENT)
    draw.text((WIDTH - 180, 178), "AA", font=font(48, bold=True), fill=PAPER, anchor="ma")

    # 底栏进度
    draw.rectangle([0, HEIGHT - 320, WIDTH, HEIGHT], fill=(24, 22, 22))
    draw.rounded_rectangle([60, HEIGHT - 210, WIDTH - 60, HEIGHT - 190], radius=10,
                           fill=(70, 68, 72))
    draw.rounded_rectangle([60, HEIGHT - 210, 60 + int((WIDTH - 120) * 0.28), HEIGHT - 190],
                           radius=10, fill=ACCENT)
    draw.text((60, HEIGHT - 160), "12 / 48", font=font(40), fill=(200, 197, 195))
    draw.text((WIDTH - 60, HEIGHT - 160), "Translating… 2 left", font=font(40),
              fill=ACCENT, anchor="ra")
    return image


def screen_translation_settings():
    image = Image.new("RGB", (WIDTH, HEIGHT), CARD)
    draw = ImageDraw.Draw(image)
    status_bar(draw)
    nav_bar(draw, "Translation")

    rows = [
        ("Backend", "Cloud service"),
        ("Source language", "Japanese"),
        ("Target language", "English"),
        ("Prefetch", "2 pages each way"),
        ("Own key", "Not set"),
        ("Typesetting", "Sample background"),
        ("Cache", "128 pages"),
    ]
    y = 300
    for label, value in rows:
        draw.rounded_rectangle([40, y, WIDTH - 40, y + 150], radius=20, fill=PAPER)
        draw.text((80, y + 34), label, font=font(42, bold=True), fill=INK)
        draw.text((80, y + 88), value, font=font(38), fill=MUTED)
        y += 166

    draw.text((80, y + 40), "Privacy: only recognised text leaves the device.",
              font=font(34), fill=MUTED)

    # 底部：额度与升级入口示意
    draw.rounded_rectangle([40, HEIGHT - 420, WIDTH - 40, HEIGHT - 220], radius=24,
                           fill=ACCENT)
    draw.text((80, HEIGHT - 370), "10 of 10 pages left today",
              font=font(42, bold=True), fill=PAPER)
    draw.text((80, HEIGHT - 300), "Upgrade for unlimited",
              font=font(38), fill=(220, 216, 246))
    return image


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    screens = {
        "library": screen_library(),
        "reader": screen_reader(),
        "translation": screen_translation_settings(),
    }
    for name, image in screens.items():
        path = os.path.join(OUT_DIR, f"{name}.png")
        image.save(path, optimize=True)
        print(f"✅ {path}  {image.width}x{image.height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
