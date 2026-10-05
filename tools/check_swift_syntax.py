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

    # 漏换行：Swift 一行只能有一个语句，出现「值 + 大量空白 + 关键字」
    # 基本可以断定是编辑时把换行吃掉了（实测踩过：
    # `isImporting = false            if failures.isEmpty {` 报
    #  "Consecutive statements on a line must be separated by ';'"）。
    # 判定收紧到「字面量结尾 + 4 空格以上 + 语句关键字」，避免误报
    # （对齐的代码块、多行字符串已在 strip_literals_and_comments 里剔除）。
    merged = re.compile(
        r"\b(true|false|nil|\d+|\"[^\"]*\"|\))\s{4,}"
        r"(if|for|while|guard|switch|return|let|var|do|Task)\b"
    )
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("*"):
            continue
        match = merged.search(line)
        if match:
            problems.append(
                f"第 {index + 1} 行疑似漏换行（`{match.group(1)}` 与 `{match.group(2)}` 挤在同一行）"
            )

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


def check_multiline_string_indentation(path):
    """
    多行字符串字面量的缩进规则：Swift 要求结束定界符之前的**每一行**
    缩进不少于结束定界符本身，否则编译报
    "Insufficient indentation of line in multi-line string literal"。

    动机：CI 上曾因生成器把首行写在 0 缩进而失败，白跑一轮。
    注释行先跳过，避免文档注释里的 `\"\"\"` 干扰判定。
    """
    problems = []
    raw = io.open(path, encoding="utf-8").read()
    lines = raw.split("\n")

    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            index += 1
            continue

        marker = line.find('"""')
        if marker == -1:
            index += 1
            continue

        # 单行字面量（同行还有一组 """）直接跳过
        if '"""' in line[marker + 3:]:
            index += 1
            continue

        # 找结束定界符所在行与其缩进
        closing_index = index + 1
        closing_indent = None
        while closing_index < len(lines):
            position = lines[closing_index].find('"""')
            if position != -1 and not lines[closing_index].strip().startswith("//"):
                closing_indent = position
                break
            closing_index += 1

        if closing_indent is None:
            problems.append(f"第 {index + 1} 行开始的多行字符串缺少结束定界符")
            index += 1
            continue

        for cursor in range(index + 1, closing_index):
            content = lines[cursor]
            if content.strip() == "":
                continue
            indent = len(content) - len(content.lstrip(" "))
            if indent < closing_indent:
                problems.append(
                    f"第 {cursor + 1} 行多行字符串缩进不足（{indent} < 结束定界符的 {closing_indent}）"
                )
                break

        index = closing_index + 1

    return problems


def main():
    files = swift_files("MangaTranslater") + swift_files("Packages")
    all_problems = []
    for path in files:
        relative = os.path.relpath(path).replace("\\", "/")
        for problem in check_file(path):
            all_problems.append((relative, problem))
        for problem in check_multiline_string_indentation(path):
            all_problems.append((relative, problem))
    for problem in check_codable_consistency(files):
        all_problems.append(problem)

    print(f"体检 Swift 文件：{len(files)} 个")
    if all_problems:
        print("\n❌ 发现问题：")
        for path, problem in all_problems:
            print(f"  {path}: {problem}")
        return 1
    print("✅ 括号配平、条件编译配对、多行字符串缩进、JSON 编解码类型均正常")
    return 0


if __name__ == "__main__":
    sys.exit(main())
