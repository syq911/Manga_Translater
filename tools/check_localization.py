#!/usr/bin/env python3
"""
本地化一致性检查（本地预检工具）。

动机：`L("key")` 取不到字符串时**不会编译报错**，只在运行期把 key 原样显示出来
（或回退到开发语言），而这类问题通常要等界面上线被人看到才发现。纯文本即可判定：

1. 所有语言的 `Localizable.strings` **key 集合必须一致**——否则某个语言会缺文案；
2. 代码里出现的每个 `L("…")` 都必须在字符串表里存在——否则界面会显示原始 key；
3. 同一个 key 的**占位符数量与类型必须一致**——否则译文会串位或崩在
   `String(format:)` 上（实测踩过：`%d` 配 Swift 的 64 位 `Int`、以及
   `%@` 与 `%1$@` 混用导致同一个参数被吃两次）。

字符串表用轻量正则解析：本项目的 `.strings` 只用到 `"key" = "value";` 这一种形式
（含注释行与转义引号），引入 plist 解析器属于过度设计。
"""

import io
import os
import re
import sys

SKIP_DIRS = {".git", ".build", "DerivedData", "build", ".swiftpm", "__pycache__"}
RESOURCES_DIR = os.path.join("MangaTranslater", "Resources")
SWIFT_ROOTS = ("MangaTranslater", "Packages")

ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
USAGE = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"\s*\)')

# 常见占位符：%@ %d %ld %s %f，以及带位置的 %1$@ 形式
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|h|ll|l|z|t|j)?([@difsuxXeEgGc])")


def swift_files():
    found = []
    for root in SWIFT_ROOTS:
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in files:
                if name.endswith(".swift"):
                    found.append(os.path.join(dirpath, name))
    return sorted(found)


def parse_strings(path):
    text = io.open(path, encoding="utf-8").read()
    entries = {}
    for match in ENTRY.finditer(text):
        entries[match.group(1)] = match.group(2)
    return entries


def placeholders(value):
    """取出占位符描述序列：[(位置或 None, 类型)]。"""
    return [(match.group(1), match.group(2)) for match in PLACEHOLDER.finditer(value)]


def main():
    if not os.path.isdir(RESOURCES_DIR):
        print(f"❌ 找不到资源目录：{RESOURCES_DIR}")
        return 1

    language_files = {}
    for name in sorted(os.listdir(RESOURCES_DIR)):
        if not name.endswith(".lproj"):
            continue
        strings_path = os.path.join(RESOURCES_DIR, name, "Localizable.strings")
        if os.path.isfile(strings_path):
            language_files[name] = parse_strings(strings_path)

    if not language_files:
        print("❌ 没有找到任何 Localizable.strings")
        return 1

    problems = []

    # 1. 各语言的 key 集合以**并集**为基准。
    #    不要拿「第一个文件」当基准：那样一旦是它少了 key，报出来的方向会反过来
    #    （变成「别的语言多了一个 key」），读的人得先在脑子里倒一次。
    union = set()
    for entries in language_files.values():
        union |= set(entries)

    for name, entries in sorted(language_files.items()):
        missing = sorted(union - set(entries))
        if missing:
            problems.append(f"{name}: 缺少 {len(missing)} 个 key（如 {', '.join(missing[:5])}）")

    # 2. 同一个 key 的占位符必须一致（各语言两两比较，等价于「签名集合大小 == 1」）
    signatures = {}
    for name, entries in sorted(language_files.items()):
        for key, value in entries.items():
            signature = tuple((position, kind) for position, kind in placeholders(value))
            signatures.setdefault(key, []).append((name, signature))

    for key, samples in sorted(signatures.items()):
        if len(samples) < 2:
            continue
        distinct = {signature for _, signature in samples}
        if len(distinct) > 1:
            detail = "，".join(
                f"{name}：{'无占位符' if not signature else '…'.join(kind for _, kind in signature)}"
                for name, signature in samples
            )
            problems.append(f"`{key}` 各语言占位符不一致（{detail}）")

    # 3. 代码里用到的 key 必须存在
    used = {}
    for path in swift_files():
        text = io.open(path, encoding="utf-8").read()
        for match in USAGE.finditer(text):
            key = match.group(1)
            used.setdefault(key, set()).add(os.path.relpath(path).replace("\\", "/"))

    for key, files in sorted(used.items()):
        if key in union:
            continue
        problems.append(f"代码使用了未定义的 key `{key}`（{', '.join(sorted(files))}）")

    # 4. `String(format:)` 的参数个数要与占位符数量吻合
    reference = language_files[sorted(language_files)[0]]
    for key, files in sorted(used.items()):
        value = reference.get(key)
        if value is None:
            continue
        count = len(placeholders(value))
        if count == 0:
            continue
        for path in sorted(files):
            text = io.open(path, encoding="utf-8").read()
            pattern = re.compile(
                r'String\(format:\s*L\(\s*"' + re.escape(key) + r'"\s*\)\s*(,[^)]*)?\)'
            )
            for match in pattern.finditer(text):
                arguments = match.group(1) or ""
                actual = len([part for part in arguments.split(",") if part.strip()])
                if actual != count:
                    line = text[: match.start()].count("\n") + 1
                    problems.append(
                        f"{path}:{line} `{key}` 需要 {count} 个参数，实际传入 {actual} 个"
                    )

    total = sum(len(entries) for entries in language_files.values())
    print(f"本地化检查：{len(language_files)} 种语言，共 {total} 条文案，代码引用 {len(used)} 个 key")
    if problems:
        print("\n❌ 发现问题：")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print("✅ 多语言 key 集合一致、代码引用的 key 均已定义、占位符类型与数量匹配")
    return 0


if __name__ == "__main__":
    sys.exit(main())
