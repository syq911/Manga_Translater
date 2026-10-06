#!/usr/bin/env python3
"""
生成 OCR 金标准夹具（开发工具，不参与构建）。

产物：
  Tests/Fixtures/ocr_fixture_page.jpg      一张合成的日文对话页（中性内容）
  Tests/Fixtures/ocr_fixture_expected.txt  这张图上**确实印着**的文字（逐行）

为什么是「合成」而不是「真实页图」：
真实页图会把第三方作品内容带进公开仓库（版权 + 合规双重问题）。
合成页图同样能验证整条链路——「位图 → Vision → 文本行」——
因为我们**先知道画了什么**，基准文本就是绘制时用的文本本身，
比「人工抄一遍」更准确。

依赖：pillow（`pip install pillow`）。仅生成夹具时需要，测试本身不需要。
用法：python3 tools/make_ocr_fixture.py
"""

import os
import sys

LINES = [
    "おはよう、今日はいい天気だね",
    "ちょっと待ってください",
    "ありがとう、また明日",
    "この続きは明日読もう",
    "わかった、気をつけてね",
]

PAGE_SIZE = (1248, 1824)
FONT_SIZE = 56
# 字体候选：优先日文字体，其次中日通用字体
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msgothic.ttc",
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\simsun.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "/System/Library/Fonts/Supplemental/Osaka.ttf",
]


def pick_font():
    from PIL import ImageFont

    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, FONT_SIZE), path
            except OSError:
                continue
    raise SystemExit(
        "❌ 找不到可用的 CJK 字体。请安装字体或修改 FONT_CANDIDATES 后重试。"
    )


def main():
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        raise SystemExit("❌ 需要 pillow：pip install pillow")

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    fixtures = os.path.join(root, "Tests", "Fixtures")
    os.makedirs(fixtures, exist_ok=True)

    font, font_path = pick_font()
    image = Image.new("RGB", PAGE_SIZE, "white")
    draw = ImageDraw.Draw(image)

    # 行距充足 + 左右留白，贴近真实对白页的稀疏排布
    y = 180
    for line in LINES:
        draw.text((110, y), line, fill="black", font=font)
        y += 300

    page_path = os.path.join(fixtures, "ocr_fixture_page.jpg")
    image.save(page_path, "JPEG", quality=92)

    expected_path = os.path.join(fixtures, "ocr_fixture_expected.txt")
    with open(expected_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(LINES) + "\n")

    print(f"✅ 已生成 {page_path}（字体 {os.path.basename(font_path)}）")
    print(f"✅ 已生成 {expected_path}（{len(LINES)} 行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
