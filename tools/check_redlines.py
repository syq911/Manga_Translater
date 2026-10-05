#!/usr/bin/env python3
"""
红线扫描（本地预检工具）。

本项目是「通用阅读器」，合规依赖三条不可退让的约束：
1. 仓库内不得出现任何具体第三方内容站点名（避免被解读为「定向提供源」）；
   本脚本按通用判定：命中已知站点关键词即报错。
2. 不得提交任何源脚本（*.js）——只允许定义接口规范。
   例外：测试夹具（Tests/Fixtures）与文档里的示例片段。
3. 不得提交凭据（token / 密钥）。

用法：python3 tools/check_redlines.py
"""

import io
import os
import re
import sys

# 已知第三方内容站点关键词（大小写不敏感）。命中即需人工确认。
SITE_KEYWORDS = [
    "nhentai", "exhentai", "hitomi", "pururin", "hentai2read", "hentai20",
    "mangadex", "mangakakalot", "batoto", "toonily", "asurascans",
    "jmcomic", "禁漫天堂", "拷贝漫画", "包子漫画", "漫画柜", "漫蛙",
    "kakao webtoon", "tapas",
]

# 凭据特征
CREDENTIAL_PATTERNS = [
    r"github_pat_[A-Za-z0-9_]{20,}",
    r"ghp_[A-Za-z0-9]{30,}",
    r"sk-[A-Za-z0-9]{20,}",
    r"AKIA[0-9A-Z]{16}",
]

SKIP_DIRS = {".git", ".build", "DerivedData", "build", ".swiftpm", "__pycache__"}
SKIP_FILES = {"check_redlines.py"}  # 本文件自身包含关键词清单
# 允许出现站点名的白名单路径（本体是「排除示例」或协议文档讨论）
ALLOWLIST = {
    "READMES.md",
}


def iter_files(root="."):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_FILES:
                continue
            yield os.path.join(dirpath, name)


def main():
    problems = []

    for path in iter_files():
        relative = os.path.relpath(path).replace("\\", "/")
        if os.path.basename(relative) in ALLOWLIST:
            continue

        # 规则 2：禁止源脚本
        if relative.endswith(".js"):
            problems.append(f"提交了 JavaScript 源脚本：{relative}（本项目只提供接口规范）")
            continue

        try:
            text = io.open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue

        lowered = text.lower()

        # 规则 1：站点名
        for keyword in SITE_KEYWORDS:
            if keyword.lower() in lowered:
                problems.append(f"出现第三方站点名「{keyword}」：{relative}")

        # 规则 3：凭据
        for pattern in CREDENTIAL_PATTERNS:
            match = re.search(pattern, text)
            if match:
                problems.append(f"疑似提交凭据：{relative}（匹配 {pattern[:16]}…）")

    if problems:
        print("❌ 红线扫描未通过：")
        seen = set()
        for item in problems:
            if item in seen:
                continue
            seen.add(item)
            print("  -", item)
        return 1

    print("✅ 红线扫描通过（无站点名、无源脚本、无凭据）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
