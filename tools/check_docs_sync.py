#!/usr/bin/env python3
"""
文档与夹具同步检查（本地预检工具）。

`docs/source-api.md` 里的「契约示例源」必须与测试夹具
`MangaTranslaterTests/SourceAPIDocTests.swift` 中的字符串**逐字一致**。

理由：示例是给源作者照抄的骨架，一旦文档与代码分叉，就会出现
「照着文档写却装不上」的体验事故。本脚本让这种分叉在推送前就被挡住。

实现要点：Swift 多行字符串会**按结束定界符的缩进**剥掉公共前导空格，
本脚本复刻同一规则后再比对。

用法：python3 tools/check_docs_sync.py
"""

import io
import re
import sys

DOC = "docs/source-api.md"
SWIFT = "MangaTranslater/MangaTranslaterTests/SourceAPIDocTests.swift"
MARKER = "// canonical-example"
CONST_NAME = "canonicalExample"


def extract_doc_block():
    text = io.open(DOC, encoding="utf-8").read()
    blocks = re.findall(r"```js\n(.*?)```", text, re.S)
    marked = [b for b in blocks if b.lstrip().startswith(MARKER)]
    if not marked:
        raise SystemExit(f"❌ {DOC} 中找不到以 `{MARKER}` 开头的 js 代码块")
    if len(marked) > 1:
        raise SystemExit(f"❌ {DOC} 中有 {len(marked)} 个 canonical 代码块，应当只有一个")
    return marked[0].rstrip("\n")


def extract_swift_literal():
    text = io.open(SWIFT, encoding="utf-8").read()
    pattern = re.compile(
        r"static let " + CONST_NAME + r'\s*=\s*"""\n(.*?)\n([ \t]*)"""',
        re.S,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"❌ 在 {SWIFT} 中找不到 `static let {CONST_NAME} = \"\"\"…\"\"\"`")

    body, closing_indent = match.group(1), match.group(2)
    lines = []
    for line in body.split("\n"):
        if line.startswith(closing_indent):
            lines.append(line[len(closing_indent):])
        else:
            lines.append(line.lstrip(" "))  # 空行或缩进不足时按空行处理
    return "\n".join(lines).rstrip("\n")


def normalize(text):
    """忽略行尾空白，避免编辑器差异造成假报警。"""
    return [line.rstrip() for line in text.split("\n")]


def main():
    doc_lines = normalize(extract_doc_block())
    swift_lines = normalize(extract_swift_literal())

    if doc_lines == swift_lines:
        print(f"✅ 文档示例与测试夹具一致（{len(doc_lines)} 行）")
        return 0

    print("❌ 文档示例与测试夹具不一致：")
    print(f"   {DOC}: {len(doc_lines)} 行 | {SWIFT}: {len(swift_lines)} 行")

    import difflib

    diff = list(
        difflib.unified_diff(
            doc_lines,
            swift_lines,
            fromfile=DOC,
            tofile=SWIFT,
            lineterm="",
            n=1,
        )
    )
    for line in diff[:40]:
        print("   ", line)
    if len(diff) > 40:
        print(f"    …（共 {len(diff)} 行差异）")
    print("\n修复：以文档为准同步夹具，或反之；两侧必须一致。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
