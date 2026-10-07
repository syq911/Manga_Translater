#!/usr/bin/env python3
"""
用户可见文案扫描（本地预检工具）。

动机：这个 App 面向中英双语用户，「中英双语」是发布门槛（手册第 12 章 M5）。
但 Swift 里写 `Text("载入中…")` 不会报错——它只是**永远显示中文**，
英文用户在英文界面里看到中文，而本地检查器无感、编译器无感。

同类问题还有一层更隐蔽的：**模型层里的 `displayName`**。
`AppCore` / `AppDatabase` / `SourceEngine` 是纯 Foundation 包，
拿不到 App 目标的 `L()`，于是那里的 `displayName` 只能是中文常量。
它一旦被界面直接渲染（设置页的 Picker 就是这么用的），
「英文界面里出现中文选项」就固化了。正确做法是：
**包层只提供语言无关的标识（枚举 case），文案全部留在 App 层的 `L("…")` 里。**

判定规则（刻意保守，把误报压到零）：

1. 只扫源码中的**字符串字面量**，注释与文档注释一律不参与（注释里出现中文是正常的）；
2. 字面量含汉字即视为「文案」，除非它出现在**只给开发者看**的调用里：
   `diag(...)` / `log(...)` / `print(...)` / `assert(...)` / `precondition(...)` /
   `fatalError(...)` 等。诊断日志的阅读者是维护者，不是用户；
3. 单行可用 `// i18n-exempt` 显式豁免（用于确有必要的例外，例如
   `#Preview` 里的中性示例数据），豁免会打印出来，便于复核而不是悄悄放过；
4. 测试目标不参与（夹具里出现中文是刻意的）。

修法：把字面量换成 `L("…")`，并在
`MangaTranslater/Resources/{en,zh-Hans}.lproj/Localizable.strings` 两侧同时补 key。

用法：python3 tools/check_hardcoded_copy.py
"""

import io
import os
import re
import sys

# 只扫这两棵子树：App 目标（含 Translation / Cloud）与本地包。
APP_ROOT = "MangaTranslater"
PACKAGE_ROOT = "Packages"
SKIP_DIR_NAMES = {".git", ".build", "DerivedData", "build", ".swiftpm", "__pycache__"}
SKIP_PATH_PARTS = ("MangaTranslaterTests",)

# 汉字 + 中日韩标点。
#
# 标点必须一起判：`"URL：\(value)"` 这种**只有全角冒号、没有汉字**的字符串，
# 用纯汉字范围扫不出来（U+FF1A 不在 CJK 统一汉字区），
# 而它同样是「英文界面里的中文」——实测漏掉过一条。
HAN = re.compile(r"[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff01-\uff60]")

# 只给开发者看的调用：这些名字后面的字符串不参与「用户可见」判定。
DEVELOPER_ONLY_CALLS = (
    "diag",
    "log",
    "logSink",
    "print",
    "debugPrint",
    "dump",
    "assert",
    "assertionFailure",
    "precondition",
    "preconditionFailure",
    "fatalError",
)

# `Copy.text("…")` / `Copy.format("…")` 是包层文案**唯一**的合法出口：
# key 本身不含汉字，因此天然不会命中本检查；这里显式列出是为了让规则可读。
PACKAGE_COPY_CALLS = ("Copy.text", "Copy.format")

EXEMPT_MARKER = "i18n-exempt"


def swift_files():
    found = []
    for root in (APP_ROOT, PACKAGE_ROOT):
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
            if any(part in dirpath.replace("\\", "/") for part in SKIP_PATH_PARTS):
                continue
            for name in sorted(files):
                if name.endswith(".swift"):
                    found.append(os.path.join(dirpath, name))
    return found


def scan(path):
    """
    返回 [(行号, 字面量, 是否开发者可见, 是否有豁免标记)]。

    实现是一条极简状态机：只关心「当前在代码里还是在字符串里」，
    以及「注释到哪结束」。之所以不用正则整体匹配，是因为 Swift 的
    `"\\(expr)"` 插值里可能嵌套字符串，正则会在第一个内层引号处跑偏。
    """
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")
    results = []

    index = 0
    length = len(text)
    line_number = 1
    while index < length:
        ch = text[index]
        nxt = text[index + 1] if index + 1 < length else ""

        # 行注释
        if ch == "/" and nxt == "/":
            while index < length and text[index] != "\n":
                index += 1
            continue

        # 块注释（含文档注释 /** … */）
        if ch == "/" and nxt == "*":
            index += 2
            while index < length and not (text[index] == "*" and index + 1 < length and text[index + 1] == "/"):
                if text[index] == "\n":
                    line_number += 1
                index += 1
            index += 2
            continue

        # 多行字符串 \"\"\" —— 整个跳过（文案通常不会写成多行字符串；
        # 真写了会在这里被忽略，由人工复核兜底）
        if text.startswith('"""', index):
            end = text.find('"""', index + 3)
            end = length if end == -1 else end + 3
            line_number += text.count("\n", index, end)
            index = end
            continue

        # 字符串字面量
        if ch == '"':
            start_line = line_number
            quote_index = index
            index += 1
            buffer = []
            while index < length:
                current = text[index]
                if current == "\\":
                    if index + 1 < length and text[index + 1] == "(":
                        # 插值：跳过配对括号内的表达式（其中的字符串不参与判定，
                        # 因为插值的产物是运行时值，不是这条字面量的文案）
                        depth = 0
                        index += 1
                        while index < length:
                            if text[index] == "(":
                                depth += 1
                            elif text[index] == ")":
                                depth -= 1
                                if depth == 0:
                                    index += 1
                                    break
                            elif text[index] == "\n":
                                line_number += 1
                            index += 1
                        continue
                    index += 2
                    continue
                if current == '"':
                    index += 1
                    break
                if current == "\n":
                    line_number += 1
                buffer.append(current)
                index += 1

            literal = "".join(buffer)
            if not HAN.search(literal):
                continue

            # 往前看：这个字面量是不是某个「只给开发者」调用的实参？
            # 取开引号之前的一小段，要求它正好以 `name(` 收尾——
            # 中间出现别的东西（另一个参数、运算符）就不算，避免把
            # `makeError(diag, "中文")` 这种误判成日志。
            head = text[max(0, quote_index - 160) : quote_index]
            # 两种判定：
            # ① 字面量正好是某个「只给开发者」调用的第一个实参（正则锚在行尾）；
            # ② 它所在的那一行本身就是一句日志调用——日志的正文常是**第二个**参数
            #    （`logSink("warn", "…")`），只靠 ① 会漏。
            line_head = text[text.rfind("\n", 0, quote_index) + 1 : quote_index].strip()
            developer_only = any(
                # `\s*` 里含换行，因此 `diag(\n  "…"` 这种换行写法也能识别；
                # `(?<![\w])` 避免把 `xdiag(` 也算上，同时允许 `diagnostics.log(`。
                re.search(r"(?<![\w])" + re.escape(name) + r"\s*\(\s*$", head)
                for name in DEVELOPER_ONLY_CALLS
            ) or any(
                re.match(r"^[A-Za-z_][\w.]*\." + re.escape(name) + r"\(", line_head)
                or re.match(r"^" + re.escape(name) + r"\(", line_head)
                for name in DEVELOPER_ONLY_CALLS
            )

            line_text = lines[start_line - 1] if 0 < start_line <= len(lines) else ""
            results.append((start_line, literal, developer_only, EXEMPT_MARKER in line_text))
            continue

        if ch == "\n":
            line_number += 1
        index += 1

    return results


def main():
    problems = []
    exempted = []
    scanned = 0

    for path in swift_files():
        scanned += 1
        relative = os.path.relpath(path).replace("\\", "/")
        for line, literal, developer_only, exempt in scan(path):
            if developer_only:
                continue
            if exempt:
                exempted.append(f"{relative}:{line} 「{literal}」")
                continue
            problems.append(f"{relative}:{line} 用户可见文案含汉字，未走 L(\"…\")：「{literal}」")

    print(f"文案扫描：{scanned} 个 Swift 文件")
    if exempted:
        print(f"\n显式豁免 {len(exempted)} 处（{EXEMPT_MARKER}）：")
        for item in exempted:
            print(f"  · {item}")

    if problems:
        print("\n❌ 发现未本地化的用户可见文案：")
        for item in problems:
            print(f"  - {item}")
        print(
            "\n修法：换成 L(\"key\")，并在 MangaTranslater/Resources/{en,zh-Hans}.lproj/"
            "Localizable.strings 两侧同时补上该 key（tools/check_localization.py 会校验）。"
        )
        return 1

    print("✅ 无未本地化的用户可见文案（诊断日志用中文是允许的）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
