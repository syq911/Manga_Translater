#!/usr/bin/env python3
"""
法务文案与 App 内置副本的同步检查（本地预检工具）。

## 为什么要检查

隐私政策 / 使用条款 / 开源许可有三份「同一内容的不同载体」：

1. `docs/legal/*.md`               —— 仓库里的正式文本（也是官网的来源）；
2. `App/Settings/LegalDocuments.swift` —— **App 内可直接阅读**的副本
   （侧载 App 不能假设用户联网，法务文本必须在设备上可读）；
3. 官网页面（由 `tools/build_website.py` 从 1 生成）。

三份分叉的后果不是「文档过时」这么轻：隐私政策里写了「我们不保存图片」，
而用户实际看到的那一份如果没写，就是对用户的误导。
所以这里**把分叉变成推送前的失败**——和 `docs/source-api.md` 与测试夹具
逐字比对是同一种做法。

## 用法

    python3 tools/check_legal_sync.py            # 检查（预检用）
    python3 tools/check_legal_sync.py --emit     # 由 .md 重新生成 Swift 副本

`--emit` 是单向的：**以 Markdown 为准**。改文案请改 `.md`，然后重跑 `--emit`。

## 实现要点

Swift 多行字符串会按结束定界符的缩进剥掉公共前导空格，本脚本复刻同一规则后再比对；
比对时忽略行尾空白，避免编辑器差异造成假报警。
"""

import io
import os
import re
import sys

DOCS_DIR = os.path.join("docs", "legal")
SWIFT = os.path.join("MangaTranslater", "App", "Settings", "LegalDocuments.swift")

# (Swift 常量名, Markdown 文件名) —— 顺序即生成顺序
DOCUMENTS = [
    ("privacyEnglish", "privacy.en.md"),
    ("privacyChinese", "privacy.zh-Hans.md"),
    ("termsEnglish", "terms.en.md"),
    ("termsChinese", "terms.zh-Hans.md"),
    ("licensesEnglish", "licenses.en.md"),
    ("licensesChinese", "licenses.zh-Hans.md"),
]

INDENT = "    "


def read_markdown(name):
    path = os.path.join(DOCS_DIR, name)
    text = io.open(path, encoding="utf-8").read()
    text = text.replace("\r\n", "\n").rstrip("\n")
    if '"""' in text:
        raise SystemExit(f"❌ {path} 含 `\"\"\"`，无法整体放进 Swift 多行字符串")
    if "\\" in text:
        raise SystemExit(
            f"❌ {path} 含反斜杠，Swift 多行字符串里需要转义、容易与原文不一致；"
            "请改写这段文案"
        )
    return text


def swift_literal(name):
    text = io.open(SWIFT, encoding="utf-8").read()
    pattern = re.compile(
        r"static let " + name + r'\s*=\s*"""\n(.*?)\n([ \t]*)"""',
        re.S,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"❌ 在 {SWIFT} 中找不到 `static let {name} = \"\"\"…\"\"\"`")
    body, closing_indent = match.group(1), match.group(2)
    lines = []
    for line in body.split("\n"):
        if line.startswith(closing_indent):
            lines.append(line[len(closing_indent):])
        else:
            lines.append(line.lstrip(" "))
    return "\n".join(lines).rstrip("\n")


def normalize(text):
    return [line.rstrip() for line in text.split("\n")]


def emit():
    blocks = []
    for name, file_name in DOCUMENTS:
        body = read_markdown(file_name)
        indented = "\n".join(
            (INDENT + line) if line.strip() else "" for line in body.split("\n")
        )
        blocks.append(f'    static let {name} = """\n{indented}\n    """')

    raw = io.open(SWIFT, encoding="utf-8").read()
    start = raw.find("// legal-documents:begin")
    end = raw.find("// legal-documents:end")
    if start == -1 or end == -1:
        raise SystemExit(f"❌ {SWIFT} 缺少 // legal-documents:begin / :end 标记")
    end = raw.index("\n", end)

    updated = raw[: start + len("// legal-documents:begin")] + "\n"
    updated += "\n\n".join(blocks)
    updated += raw[end:]
    io.open(SWIFT, "w", encoding="utf-8", newline="\n").write(updated)
    print(f"✅ 已由 {len(DOCUMENTS)} 份 Markdown 重新生成 {SWIFT}")


def check():
    problems = []
    for name, file_name in DOCUMENTS:
        expected = normalize(read_markdown(file_name))
        actual = normalize(swift_literal(name))
        if expected == actual:
            continue

        import difflib

        diff = list(
            difflib.unified_diff(
                expected,
                actual,
                fromfile=os.path.join(DOCS_DIR, file_name),
                tofile=SWIFT,
                lineterm="",
                n=1,
            )
        )
        problems.append((file_name, name, diff))

    if not problems:
        print(f"✅ 法务文案一致：{len(DOCUMENTS)} 份（docs/legal ↔ App 内置副本）")
        return 0

    print("❌ 法务文案与 App 内置副本不一致：")
    for file_name, name, diff in problems:
        print(f"\n  {file_name} ↔ {name}")
        for line in diff[:20]:
            print("   ", line)
        if len(diff) > 20:
            print(f"    …（共 {len(diff)} 行差异）")
    print("\n修复：以 docs/legal/*.md 为准，运行 `python3 tools/check_legal_sync.py --emit`。")
    return 1


def main():
    if "--emit" in sys.argv[1:]:
        emit()
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main())
