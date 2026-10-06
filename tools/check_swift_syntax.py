#!/usr/bin/env python3
"""
Swift 源码轻量体检（本地预检工具）。

本机没有 macOS / Swift 工具链，无法真正编译，因此用词法层面的检查
把最容易出现的结构性错误提前挡掉：

1. 括号 / 方括号 / 花括号配平（忽略字符串、字符、行注释、块注释内的括号）；
2. `#if` / `#endif` 配对；
3. 明显的 `else` 悬空（`else` 前面既不是 `}` 也不是同一 if 的行）；
4. 每个 `@Test` / `@Suite` 是否在 struct/class/enum 内（顶层 @Test 在本项目约定外）；
5. 实例方法里裸调用本类型的 `static` 成员（漏写 `Self.`）。

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
    """
    去掉字面量与注释，只保留「代码骨架」。

    为什么需要状态机：Swift 的字符串插值 `"\\(expr)"` 里是**代码**，
    而这段代码里又可以有字符串（例如
    `output += " \\(key)=\\"\\(value.replacingOccurrences(of: "\\"", ...))\\""`）。
    早先的实现把插值整体当字符串内容跳过，于是插值里那几个 `)` 被漏掉、
    `)` 反而在代码模式下被多计，最终报出虚假的「圆括号不配平」。

    现在用上下文栈处理：进入字符串压栈，遇到 `\\(` 视为进入代码上下文
    （并把 `(` 计入，保证配平），遇到配对的 `)` 出栈回到字符串。
    多行字符串（`\"\"\"`）整体跳过——它的括号不进不出，天然配平。
    """
    out = []
    i = 0
    n = len(text)
    # 上下文栈：("code", 本层括号深度) / ("string", 0)
    # 记录深度是必要的：插值里可能还有函数调用（`\(foo(a))`），
    # 只有当深度回到 0 时遇到的 `)` 才是「插值结束」。
    stack = [("code", 0)]

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        mode = stack[-1][0]

        # ---------- 字符串内部 ----------
        if mode == "string":
            if ch == "\\":
                if nxt == "(":
                    # 字符串插值：进入代码上下文，`(` 计入配平
                    out.append("(")
                    stack.append(("code", 0))
                    i += 2
                    continue
                i += 2            # 普通转义
                continue
            if ch == '"':
                stack.pop()
                i += 1
                continue
            i += 1
            continue

        # ---------- 代码 ----------
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue

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

        if text.startswith('"""', i):
            i += 3
            while i < n and not text.startswith('"""', i):
                i += 1
            i += 3
            continue

        # raw string：`#"..."#` / `##"..."##`（内容里的反斜杠不转义，
        # 因此正则里的 `[\[\(]` 这类字符不该被计入括号）。
        raw_match = re.match(r'(#+)"', text[i:])
        if raw_match:
            closer = '"' + raw_match.group(1)
            j = i + len(raw_match.group(0))
            while j < n and not text.startswith(closer, j):
                j += 1
            i = min(j + len(closer), n)
            continue

        if ch == '"':
            stack.append(("string", 0))
            i += 1
            continue

        if ch == "(":
            current = stack[-1]
            stack[-1] = (current[0], current[1] + 1)
            out.append("(")
            i += 1
            continue

        if ch == ")":
            current = stack[-1]
            if current[1] > 0:
                # 本层还有未闭合的括号（如插值里的函数调用）
                stack[-1] = (current[0], current[1] - 1)
            elif len(stack) > 1:
                stack.pop()       # 插值结束，回到字符串
            out.append(")")
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
    #
    # 还要放行**多行条件**：
    #
    #     guard let a,
    #           let b = f(a),
    #           b > 0
    #     else { return nil }
    #
    # 这种写法里 `else` 的上一行是 `b > 0`，既不以 `,` 也不以 `)` 结尾。
    # 判定方式是往回找这条语句的开头：只要在遇到 `{` / `}` / `;` 之前
    # 先碰到 `guard` / `if`，就说明这个 `else` 属于一个合法的条件。
    # 反过来，真正的悬空 else（前面是无关的普通语句）会在途中撞上 `}` 或
    # 一直找不到 guard/if，仍会被报出来。
    def belongs_to_condition(lines, index):
        for offset in range(1, 21):
            position = index - offset
            if position < 0:
                return False
            text = lines[position].strip()
            if not text or text.startswith("//"):
                continue
            if re.match(r"^(guard|if)\b", text):
                return True
            if text.startswith("}") or text.endswith(("{", "}", ";")):
                return False
        return False

    lines = raw.split("\n")
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not re.match(r"^else\b", stripped):
            continue
        previous = lines[index - 1].strip() if index > 0 else ""
        if previous.endswith(("{", "}", ")")):
            continue
        if belongs_to_condition(lines, index):
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

    # 几何构造函数里的裸 `.nan` / `.infinity`：同时 import Foundation 与
    # CoreGraphics 时，`CGFloat.nan` 在两个模块都有定义，会报
    # "ambiguous use of 'nan'"。要求显式写 `CGFloat.nan`。
    ambiguous = re.compile(
        r"\bCG(?:Size|Point|Rect|Vector)\([^)\n]*?(?<![\w.])\.(nan|infinity)\b"
    )
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        match = ambiguous.search(line)
        if match:
            problems.append(
                f"第 {index + 1} 行的 `.{match.group(1)}` 类型不明确，"
                f"请写成 `CGFloat.{match.group(1)}`"
            )

    return problems


def check_static_member_qualification(files):
    """
    实例方法里**裸调用**本类型的 `static` 成员。

    动机：CI 上出现过 `guard !isNull(root) else` —— Swift 不允许在实例方法中
    不加限定地调用同一类型的静态成员，报
    "static member 'isNull' cannot be used on instance of type 'X'"；
    正确写法是 `Self.isNull(root)`。纯文本即可判定，不必耗一轮 CI。

    判定要**带作用域**，否则满屏误报：静态方法里裸调静态成员完全合法
    （`static func a()` 里调 `b()`），只有「实例方法 / 实例属性初值」
    才要求限定。因此这里用花括号深度维护一个「当前所处的声明栈」，
    只有栈顶是**非 static 的 func/var/let** 时才报。

    为再避免一层误报：仅在「该名字在文件里只有 static 声明」时才判——
    同名还有实例成员或全局函数时（可能重载/遮蔽），交给编译器判断。

    另外要认得**运算符声明**（`static func == (lhs:rhs:)`）：正则若只认
    `[A-Za-z_][A-Za-z0-9_]*`，这类声明就进不了声明栈，函数体里的普通调用
    会被误判成「实例上下文裸调静态成员」（本项目实测误报过一次）。
    """
    declaration = re.compile(
        r"^[ \t]*(?P<mods>(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?[ \t]+"
        r"|public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+"
        r"|final[ \t]+|static[ \t]+|class[ \t]+)*)"
        r"(?P<kind>func|var|let)[ \t]+"
        r"(?P<name>[A-Za-z_][A-Za-z0-9_]*|[/=\-+!*%<>&|^~?][/=\-+!*%<>&|^~?]*)",
        re.M,
    )

    problems = []
    for path in files:
        raw = io.open(path, encoding="utf-8").read()
        code = strip_literals_and_comments(raw)

        declarations = []
        static_names = set()
        other_names = set()
        for match in declaration.finditer(code):
            is_static = "static" in match.group("mods").split()
            name = match.group("name")
            declarations.append((match.start(), name, is_static, match.group("kind") == "func"))
            if is_static:
                static_names.add(name)
            else:
                other_names.add(name)

        candidates = static_names - other_names
        if not candidates:
            continue

        # 每个字符位置的花括号深度（`{` 记外层深度，`}` 记闭合后的外层深度）
        depths = []
        depth = 0
        for ch in code:
            if ch == "}":
                depth -= 1
            depths.append(depth)
            if ch == "{":
                depth += 1

        sites = []
        for name in sorted(candidates):
            for match in re.finditer(r"(?<![\w.])" + re.escape(name) + r"\s*\(", code):
                prefix = code[: match.start()]
                # 声明行本身（`static func name(`）不是调用
                if re.search(r"(?:func|var|let)\s*$", prefix):
                    continue
                sites.append((match.start(), name))
        if not sites:
            continue

        # 声明栈：[(声明所在深度, 是否 static, 是否函数体)]。
        # 关键细节：函数**体内**的 `let` / `var` 是局部语句，不能当作新作用域压栈，
        # 否则顶层 `static func` 会被它顶掉，静态成员调用全成了「实例上下文」。
        contexts = []
        cursor = 0
        for position, name in sorted(sites):
            while cursor < len(declarations):
                start, _, is_static, is_function = declarations[cursor]
                if start >= position:
                    break
                declared_at = depths[start]
                while contexts and contexts[-1][0] >= declared_at:
                    contexts.pop()
                # 只要「最近的上下文是函数体，且本声明比它更深」，就是函数体内的
                # 局部语句（`let` / `var`），不能当新作用域压栈。
                # 注意不能要求 `declared_at == 上下文深度 + 1`：`for` / `if` 块里的
                # 局部变量会更深，早先按 +1 判定，结果 `for token in tokens { let x }`
                # 里的 `let` 被压栈，把外层的 `static func` 顶掉，造成误报。
                enclosed = (
                    contexts
                    and contexts[-1][2]
                    and declared_at > contexts[-1][0]
                )
                if not enclosed:
                    contexts.append((declared_at, is_static, is_function))
                cursor += 1
            if not contexts or contexts[-1][1]:
                continue       # 类型级 / 静态上下文里裸调静态成员是合法的
            line = code[:position].count("\n") + 1
            problems.append(
                (
                    os.path.relpath(path).replace("\\", "/"),
                    f"第 {line} 行在实例方法里裸调用静态成员 `{name}`；"
                    f"请写成 `Self.{name}(…)`",
                )
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


def check_unsanitized_path_components(files):
    """
    把「像主键的标识」直接当路径片段用。

    动机：本项目的章节主键是 `<mangaID>|<url>`，**必然含 `/`**（URL 就在里面）。
    直接 `appendingPathComponent(jobID)` 只有两种结局：
    路径穿越，或者（早期实现的做法）一律拒绝含 `/` 的 ID —— 实测后果是
    **所有在线章节的下载都在第一步报「任务标识不合法」**，功能整个走不通。
    正确做法是经过 `FileNameSanitizer.segment(...)`。

    判定很精确、几乎没有误报：只有当 `appendingPathComponent(` 的**第一个**
    实参就是裸标识符（`jobID` / `mangaID` / `chapterID` / `sourceID`）时才报。
    经过 `segment(...)` 或 `FileNameSanitizer.segment(...)` 的写法不会被匹配到
    （第一个实参是调用表达式，不是裸标识符）。
    """
    key_like = {"jobID", "mangaID", "chapterID", "sourceID"}
    pattern = re.compile(
        r"appendingPathComponent\s*\(\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*[,)]"
    )
    problems = []
    for path in files:
        raw = io.open(path, encoding="utf-8").read()
        code = strip_literals_and_comments(raw)
        for match in pattern.finditer(code):
            name = match.group("name")
            if name not in key_like:
                continue
            line = code[: match.start()].count("\n") + 1
            problems.append(
                (
                    os.path.relpath(path).replace("\\", "/"),
                    f"第 {line} 行把 `{name}` 直接当路径片段；"
                    f"主键含 `/`，请写成 `FileNameSanitizer.segment({name})`",
                )
            )
    return problems


def strip_comments_keep_literals(text):
    """
    把注释替换成**空白**（保留换行），字符串字面量原样保留。

    两个细节都是被误报逼出来的：

    - 保留换行：否则行号会整体前移，报出来的行号对不上代码；
    - 保留字符串：本项目的 `strip_literals_and_comments` 会把字符串抹成空，
      于是 `contains("\\u{0}")` 变成 `contains()`，
      在「找无参调用」的场景下会凭空造出调用。
      至于字符串里出现 `foo()` 这种内容（例如 `@Test("books() 从文件系统…")`），
      由调用点再做一次「这个位置是不是在字符串里」的判定挡掉。
    """
    out = []
    index = 0
    length = len(text)
    in_block = False
    while index < length:
        if in_block:
            if text.startswith("*/", index):
                in_block = False
                out.append("  ")
                index += 2
                continue
            out.append("\n" if text[index] == "\n" else " ")
            index += 1
            continue
        if text.startswith("/*", index):
            in_block = True
            out.append("  ")
            index += 2
            continue
        if text.startswith("//", index):
            while index < length and text[index] != "\n":
                out.append(" ")
                index += 1
            continue
        out.append(text[index])
        index += 1
    return "".join(out)


def check_unguarded_throwing_calls(files):
    """
    调用**无参 throwing 方法**却没写 `try`。

    动机（实测烧了一轮 CI）：`cookieJar.persist()` 是 throwing，
    漏写 `try` 直接编译失败（"call can throw, but it is not marked with 'try'"）。

    两条刻意的收窄，为的是把误报压到零：

    1. **只看无参调用**。无参调用必定写在一整行里，判定不需要跨行推断
       （`try foo(` 换行写参数的形式正则判不了）。有参的情况交给编译器。
    2. **该名字必须只以 throwing 形式出现**。同名另有非 throwing 声明就直接跳过——
       `makeRuntime()` 在测试里既有 throwing 重载又有普通重载，
       光看名字会把普通那次也报出来。

    声明侧的解析要看**整段签名**：`func f(` 换行写参数、`throws` 出现在闭括号之后，
    只在同一行里找 `()` 和 `throws` 会漏掉一半声明（这正是第一版误报的来源）。

    调用侧**只去注释、不去字符串字面量**：本项目通用的 `strip_literals_and_comments`
    会把字符串抹成空，于是 `contains("\\u{0}")` 变成 `contains()`，
    被当成「无参调用」——这是第二版误报的来源。
    """
    # 声明：从 `func NAME` 往后到第一个 `{` 之前找 `throws`
    declaration = re.compile(r"\bfunc\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)")
    throwing_names = set()
    plain_names = set()
    for path in files:
        raw = io.open(path, encoding="utf-8").read()
        code = strip_literals_and_comments(raw)
        for match in declaration.finditer(code):
            name = match.group("name")
            body_start = code.find("{", match.end())
            signature = code[match.end(): body_start if body_start != -1 else match.end() + 500]
            if re.search(r"\bthrows\b", signature):
                throwing_names.add(name)
            else:
                plain_names.add(name)

    # 必须**每个**同名声明都是 throwing 才算候选：只要存在一个非 throwing 的重载，
    # 调用点就可能落在它身上（`makeRuntime()` 在测试里就有两个版本）。
    candidates = throwing_names - plain_names
    # 排除与标准库同名的方法：`Array.removeAll()` 不抛错，而项目里可能恰好
    # 有一个 `func removeAll() throws`（例如某个 store），照名字判会大量误报。
    stdlib_zero_arg = {
        "removeAll", "removeFirst", "removeLast", "sorted", "reversed",
        "reset", "flush", "sync", "commit", "rollback", "close", "open",
        "cancel", "invalidate", "wait", "notify", "resume", "suspend",
    }
    candidates -= stdlib_zero_arg
    if not candidates:
        return []

    call = re.compile(
        r"(?<![A-Za-z0-9_])(?P<name>" + "|".join(sorted(map(re.escape, candidates))) + r")\s*\(\s*\)"
    )
    problems = []
    for path in files:
        raw = io.open(path, encoding="utf-8").read()
        code = strip_comments_keep_literals(raw)
        for index, line in enumerate(code.split("\n"), start=1):
            # 声明行本身不是调用
            if re.search(r"\bfunc\s", line):
                continue
            for match in call.finditer(line):
                prefix = line[: match.start()]
                if re.search(r"\btry[?!]?\s*$|\btry[?!]?\s", prefix):
                    continue
                # 落在字符串字面量里的 `foo()`（例如测试名 `@Test("books() …")`）不是调用
                if prefix.count('"') % 2 == 1:
                    continue
                problems.append(
                    (
                        os.path.relpath(path).replace("\\", "/"),
                        f"第 {index} 行调用 throwing 方法 `{match.group('name')}()` 却没写 try；"
                        f"不需要处理错误时用 `try?`",
                    )
                )
    return problems


def check_iso8601_style_usage(files):
    """
    `Date.ISO8601FormatStyle.year()` 这种**在类型上**调实例方法。

    动机（实测烧了一轮 CI）：`ISO8601FormatStyle` 的 `year()` / `month()` 等
    是**实例方法**，`Date.ISO8601FormatStyle.year()` 会被编译器拒绝
    （"instance member 'year' cannot be used on type"），
    要写成 `Date.ISO8601FormatStyle().year()`。
    判定：`ISO8601FormatStyle` 后面紧跟 `.` 而不是 `(`。
    """
    pattern = re.compile(r"ISO8601FormatStyle\s*\.\s*[A-Za-z_]")
    problems = []
    for path in files:
        raw = io.open(path, encoding="utf-8").read()
        code = strip_literals_and_comments(raw)
        for match in pattern.finditer(code):
            line = code[: match.start()].count("\n") + 1
            problems.append(
                (
                    os.path.relpath(path).replace("\\", "/"),
                    f"第 {line} 行在类型上调用 ISO8601FormatStyle 的实例方法；"
                    f"应写 `Date.ISO8601FormatStyle().year()` 或改用 `ISO8601DateFormatter`",
                )
            )
    return problems


def check_payload_column_consistency(files):
    """
    `payload` 与投影列的一致性。

    书架条目用「一列 payload（完整模型 JSON）+ 若干投影列（排序/筛选用）」存储，
    **payload 才是唯一事实来源**。任何 `UPDATE library_entry` 如果只改了投影列
    而不写 payload，就会出现「读出来的条目仍是旧值」的矛盾状态。

    实测踩过：删除分类时把 `category_id` 置空却没动 payload，
    结果条目读回来仍带着已删除的分类。

    规则：字符串字面量里出现 `UPDATE` 且涉及条目表时，必须同时出现 `payload`。
    """
    literal = re.compile(r'"""((?:.|\n)*?)"""|"((?:[^"\\]|\\.)*)"')
    problems = []
    for path in files:
        text = io.open(path, encoding="utf-8").read()
        for match in literal.finditer(text):
            body = match.group(1) or match.group(2) or ""
            if "UPDATE" not in body:
                continue
            touchesEntries = "LibraryTable.entries" in body or "library_entry" in body
            if not touchesEntries:
                continue
            if "payload" not in body:
                line = text[: match.start()].count("\n") + 1
                problems.append(
                    (
                        os.path.relpath(path).replace("\\", "/"),
                        f"第 {line} 行的 UPDATE 改动了条目表却没有写 payload"
                        "（payload 是唯一事实来源，只改投影列会导致读出的数据与列不一致）",
                    )
                )
    return problems


def check_main_actor_static_usage(files):
    """
    在**非** `@MainActor` 上下文里调用 `@MainActor` 类型的静态成员。

    动机（实测烧了一轮 CI）：`CloudAccountModel` 是 `@MainActor` 类，它的
    `static func mask(_:)` 因此继承了主 actor 隔离；而 `Mask` 是纯字符串函数，
    在不隔离的测试用例里调用会直接编译失败：

        error: call to main actor-isolated static method 'mask' in a
               synchronous nonisolated context

    这类错误的特点是**只有测试目标会报**（App 目标里的调用都在主 actor 上），
    因此更值得提前挡掉——不挡就要为它单独等一轮 CI。

    判定刻意保守，把误报压到零：

    1. 只看**声明行带 `@MainActor`** 的类型（含注解写在声明前一两行的情况）；
    2. 只收集它内部的 `static func` / `static var` / `static let` 名字，
       **排除已标 `nonisolated` 的**——那些本来就可以从任何上下文调用；
    3. 只在**测试目标、且整个文件都不含 `@MainActor`** 时才检查调用。
       两条收窄都是被真实误报逼出来的：
       - 一旦文件里有任何主 actor 上下文（例如 `@MainActor struct Suite`），
         就整篇跳过——检查器没有能力区分作用域，那就干脆不判；
       - App 目标里的 SwiftUI 代码（`body`、`#Preview`）本身就在主 actor 上，
         但文件里**没有 `@MainActor` 字面量**，照字面判会把
         `AppEnvironment.makeDefault()` 这类合法调用全报成错。
         而这类错误的实际发生地是测试目标（App 目标的调用都在主 actor 上），
         所以只查测试文件既覆盖了真问题，又不会误伤 UI 代码。

    修法二选一：给成员加 `nonisolated`（纯函数就该这样），
    或把调用方也标成 `@MainActor`。
    """
    type_decl = re.compile(
        r"^(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
        r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
        r"(?:class|struct|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    static_member = re.compile(r"\bstatic\s+(?:func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")

    main_actor_members = {}
    for path in files:
        raw = io.open(path, encoding="utf-8").read()
        current_type = None
        pending_actor = False
        for line in raw.split("\n"):
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            if "@MainActor" in line and "(" not in stripped.split("@MainActor")[0]:
                pending_actor = True
            indent = len(line) - len(line.lstrip(" "))
            if indent == 0:
                match = type_decl.match(line)
                if match:
                    current_type = match.group(1)
                    if pending_actor or "@MainActor" in line:
                        main_actor_members.setdefault(current_type, set())
                    pending_actor = False
                elif not stripped.startswith(("@", "}", ")", "#")):
                    current_type = None
                    pending_actor = False
                continue
            if current_type is None or current_type not in main_actor_members:
                continue
            if "nonisolated" in stripped:
                continue          # 已显式解除隔离，任何上下文都能调
            for match in static_member.finditer(stripped):
                main_actor_members[current_type].add(match.group(1))

    problems = []
    for path in files:
        relative = os.path.relpath(path).replace("\\", "/")
        if "MangaTranslaterTests/" not in relative:
            continue          # 只查测试目标（见上文第 3 条）
        raw = io.open(path, encoding="utf-8").read()
        if "@MainActor" in raw:
            continue          # 文件里有主 actor 上下文 → 不判
        code = strip_literals_and_comments(raw)
        for type_name, members in sorted(main_actor_members.items()):
            for member in sorted(members):
                pattern = re.compile(
                    r"(?<![\w.])" + re.escape(type_name) + r"\s*\.\s*" + re.escape(member) + r"\s*\("
                )
                for match in pattern.finditer(code):
                    line = code[: match.start()].count("\n") + 1
                    problems.append(
                        (
                            relative,
                            f"第 {line} 行在非主 actor 上下文里调用 `{type_name}.{member}(…)`；"
                            f"它是 `@MainActor` 类型的静态成员，请在声明处加 `nonisolated`"
                            f"（纯函数应当如此），或让调用方也处于主 actor",
                        )
                    )
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
    for problem in check_static_member_qualification(files):
        all_problems.append(problem)
    for problem in check_payload_column_consistency(files):
        all_problems.append(problem)
    for problem in check_unsanitized_path_components(files):
        all_problems.append(problem)
    for problem in check_iso8601_style_usage(files):
        all_problems.append(problem)
    for problem in check_unguarded_throwing_calls(files):
        all_problems.append(problem)
    for problem in check_main_actor_static_usage(files):
        all_problems.append(problem)

    print(f"体检 Swift 文件：{len(files)} 个")
    if all_problems:
        print("\n❌ 发现问题：")
        for path, problem in all_problems:
            print(f"  {path}: {problem}")
        return 1
    print("✅ 括号配平、条件编译配对、多行字符串缩进、JSON 编解码类型、"\
          "静态成员限定、主 actor 静态成员、路径片段安全化、日期写法、throwing 调用均正常")
    return 0


if __name__ == "__main__":
    sys.exit(main())
