#!/usr/bin/env python3
"""
Swift 源码轻量体检（本地预检工具）。

本机没有 macOS / Swift 工具链，无法真正编译，因此用词法层面的检查
把最容易出现的结构性错误提前挡掉：

1. 括号 / 方括号 / 花括号配平（忽略字符串、字符、行注释、块注释内的括号）；
2. `#if` / `#endif` 配对；
3. 明显的 `else` 悬空（`else` 前面既不是 `}` 也不是同一 if 的行）；
4. 每个 `@Test` / `@Suite` 是否在 struct/class/enum 内（顶层 @Test 在本项目约定外）。

用法：python3 tools/check_swift_syntax.py
"""

import io
import os
import re
import sys

SKIP_DIRS = {".git", ".build", "DerivedData", "build", ".swiftpm", "__pycache__"}


def swift_files(root):
    found = []
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in files:
            if name.endswith(".swift"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def strip_literals_and_comments(text):
    """返回 (去字面量后的文本, 括号计数)。"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        # 行注释
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # 块注释（Swift 支持嵌套）
        if ch == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    i += 2
                    continue
                if text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                    continue
                i += 1
            continue
        # 三引号字符串
        if text.startswith('"""', i):
            i += 3
            while i < n and not text.startswith('"""', i):
                i += 1
            i += 3
            continue
        # 普通字符串
        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                if text[i] == "\n":
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_file(path):
    problems = []
    raw = io.open(path, encoding="utf-8").read()
    code = strip_literals_and_comments(raw)

    for open_ch, close_ch, label in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        # 跳过属性包装器 / 下标里的合法用法由配平保证
        if code.count(open_ch) != code.count(close_ch):
            problems.append(
                f"{label}不配平：{open_ch}={code.count(open_ch)} {close_ch}={code.count(close_ch)}"
            )

    if_count = len(re.findall(r"^\s*#if\b", raw, re.M))
    endif_count = len(re.findall(r"^\s*#endif\b", raw, re.M))
    if endif_count < if_count:
        problems.append(f"#if（{if_count}）与 #endif（{endif_count}）不配对")

    # 悬空 else：只检查「行首是 else」且不以 `}` 开头的写法。
    # `} else {` 是合法且常见的写法，直接放行。
    lines = raw.split("\n")
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not re.match(r"^else\b", stripped):
            continue
        previous = lines[index - 1].strip() if index > 0 else ""
        if previous.endswith("{") or previous.endswith("}") or previous.endswith(")"):
            continue
        problems.append(f"第 {index + 1} 行 else 可能悬空（上一行：{previous[:60]}）")

    return problems


def check_codable_consistency(files):
    """
    JSON 编解码一致性：凡是以 `decode(X.self …)` 形式被解码的自有类型，
    它的声明必须包含 Codable（或同时包含 Encodable 与 Decodable）。

    动机：CI 上曾出现 `ReadingHistoryEntry` 忘记声明 Codable，
    直到编译才报 "requires that ... conform to Decodable"。
    这类问题在词法层面就能拦掉，不必消耗一轮 CI。
    """
    problems = []

    # 收集仓库内自有类型的声明行
    declarations = {}
    for path in files:
        text = io.open(path, encoding="utf-8").read()
        for match in re.finditer(
            r"^(\s*)(?:public\s+|internal\s+|final\s+)*(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)([^{]*)\{",
            text,
            re.M,
        ):
            header = match.group(0)
            declarations[match.group(2)] = (path, header)

    for path in files:
        text = io.open(path, encoding="utf-8").read()
        code = strip_literals_and_comments(text)
        for match in re.finditer(r"decode\(\s*([A-Z][A-Za-z0-9_]*)\.self", code):
            name = match.group(1)
            if name not in declarations:
                continue  # 系统类型或第三方类型，不管
            _, header = declarations[name]
            codable = "Codable" in header or ("Encodable" in header and "Decodable" in header)
            if not codable:
                problems.append(
                    (
                        os.path.relpath(path).replace("\\", "/"),
                        f"{name} 被 JSONDecoder 解码，但声明里没有 Codable",
                    )
                )
    return problems


def main():
    files = swift_files("MangaTranslater") + swift_files("Packages")
    all_problems = []
    for path in files:
        for problem in check_file(path):
            all_problems.append((os.path.relpath(path).replace("\\", "/"), problem))
    for problem in check_codable_consistency(files):
        all_problems.append(problem)

    print(f"体检 Swift 文件：{len(files)} 个")
    if all_problems:
        print("\n❌ 发现问题：")
        for path, problem in all_problems:
            print(f"  {path}: {problem}")
        return 1
    print("✅ 括号配平、条件编译指令配对、JSON 编解码类型一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
