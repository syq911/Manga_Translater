#!/usr/bin/env python3
"""
本地化一致性检查（本地预检工具）。

动机：`L("key")` / `Copy.text("key")` 取不到字符串时**不会编译报错**，
只在运行期把 key 原样显示出来（或回退到开发语言），
而这类问题通常要等界面上线被人看到才发现。纯文本即可判定。

## 两张表，两个命名空间

本项目的文案分布在两个互相独立的地方，**必须分开校验**：

| 表 | 位置 | 谁在用 | 访问方式 |
|---|---|---|---|
| App 表 | `MangaTranslater/Resources/<lang>.lproj/Localizable.strings` | App 目标（界面） | `L("…")` |
| 包层表 | `Packages/AppCore/Sources/AppCore/Resources/<lang>.lproj/Localizable.strings` | 五个本地包（错误与状态文案） | `Copy.text("…")` |

分成两表的原因：包是纯 Foundation 模块，**不能反向依赖 App 目标**，
因此拿不到 App 的 `L()`。两表的 key 不得互串——「取错表」的表现是
界面上冒出一个 key 字符串，而这里能在推送前就拦住。

## 检查项

1. 同一张表内，各语言的 **key 集合必须一致**（以并集为基准）；
2. 代码里用到的 key 必须在对应表里存在；
3. 同一个 key 的**占位符数量与类型必须一致**（否则译文串位或崩在 `String(format:)`）；
4. `String(format: L("key"), …)` 的实参个数必须与占位符数量吻合；
5. **死文案**：表里定义了但代码从未引用的 key（少一条文案没人发现，
   多一条没人用的文案也没人发现——都一样是腐化）；
6. **重复 key**：同一文件里同一个 key 出现两次，后一条静默生效；
7. 两张表的 key 不得重名。

注释会被先剥掉再扫描：文档注释里写 `L("…")` 是举例，不是引用
（早先的实现没剥注释，于是要求表里必须有一个叫 `…` 的 key）。

字符串表用轻量正则解析：本项目的 `.strings` 只用到 `"key" = "value";` 这一种形式。
"""

import io
import os
import re
import sys

SKIP_DIRS = {".git", ".build", "DerivedData", "build", ".swiftpm", "__pycache__"}

APP_TABLE_DIR = os.path.join("MangaTranslater", "Resources")
PACKAGE_TABLE_DIR = os.path.join("Packages", "AppCore", "Sources", "AppCore", "Resources")

ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
APP_USAGE = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"\s*\)')
PACKAGE_USAGE = re.compile(r'\bCopy\.(?:text|format)\(\s*"((?:[^"\\]|\\.)*)"')

# App 表里的 `String(format: L("key"), a, b)` —— 校验实参个数
FORMAT_CALL_PREFIX = r'String\(format:\s*L\(\s*"%s"\s*\)'


def skip_string(code, index):
    """`code[index]` 是开引号；返回闭引号之后的下标。"""
    i = index + 1
    while i < len(code):
        if code[i] == "\\":
            i += 2
            continue
        if code[i] == '"':
            return i + 1
        i += 1
    return len(code)


def format_call_arguments(code, key):
    """
    找出 `String(format: L("key"), …)` 的实参个数，返回 [(行号, 个数)]。

    必须做括号配对：实参里常有嵌套调用（`L("a"), author`），
    用 `[^)]*` 这种正则会在内层 `)` 处提前截断，把 2 个参数数成 1 个
    （实测踩过，报出「需要 2 个参数，实际传入 1 个」的假错误）。
    """
    results = []
    pattern = re.compile(FORMAT_CALL_PREFIX % re.escape(key))
    for match in pattern.finditer(code):
        open_index = code.index("(", match.start() + len("String"))
        depth = 0
        i = open_index
        while i < len(code):
            ch = code[i]
            if ch == '"':
                i = skip_string(code, i)
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        arguments = code[match.end():i]
        # 顶层逗号数 == 实参个数（`L("key"` 后面直接跟 `)` 时为 0 个）
        count = 0
        depth = 0
        j = 0
        while j < len(arguments):
            ch = arguments[j]
            if ch == '"':
                j = skip_string(arguments, j)
                continue
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "," and depth == 0:
                count += 1
            j += 1
        results.append((code[: match.start()].count("\n") + 1, count))
    return results

PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|h|ll|l|z|t|j)?([@difsuxXeEgGc])")


def swift_files(roots):
    found = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in sorted(files):
                if name.endswith(".swift"):
                    found.append(os.path.join(dirpath, name))
    return found


def strip_comments(text):
    """
    去掉 `//…` 与 `/*…*/`，保留字符串字面量。

    Swift 的 `"\\(expr)"` 插值里可能嵌套字符串，因此这里用与
    `check_swift_syntax` 同构的状态机（代码 / 字符串 / 多行字符串）。
    返回等长文本（注释位置替换为空格），便于按行号定位。
    """
    out = []
    i = 0
    n = len(text)
    mode = "code"
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if mode == "code":
            if ch == "/" and nxt == "/":
                while i < n and text[i] != "\n":
                    out.append(" ")
                    i += 1
                continue
            if ch == "/" and nxt == "*":
                out.append("  ")
                i += 2
                while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
                out.append("  ")
                i += 2
                continue
            if text.startswith('"""', i):
                out.append('"""')
                i += 3
                mode = "multiline"
                continue
            if ch == '"':
                out.append(ch)
                i += 1
                mode = "string"
                continue
            out.append(ch)
            i += 1
            continue
        if mode == "string":
            if ch == "\\":
                if nxt == "(":
                    depth = 0
                    out.append("(")
                    i += 1
                    while i < n and text[i] != ")":
                        if text[i] == "(":
                            depth += 1
                        out.append(text[i])
                        i += 1
                    out.append(")")
                    i += 1
                    continue
                out.append("  ")
                i += 2
                continue
            out.append(ch)
            if ch == '"':
                mode = "code"
            i += 1
            continue
        # multiline
        if text.startswith('"""', i):
            out.append('"""')
            i += 3
            mode = "code"
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def parse_strings(path):
    """
    解析 `"key" = "value";`。

    同时检查重复 key：`.strings` 里同一个 key 出现两次时**后一条静默生效**，
    而在文件末尾追加新文案正是本项目最常见的用法——一旦手滑重名，
    表现是「改了文案却不生效」，查起来非常费神。
    """
    counts = {}
    entries = {}
    for match in ENTRY.finditer(io.open(path, encoding="utf-8").read()):
        key = match.group(1)
        counts[key] = counts.get(key, 0) + 1
        entries[key] = match.group(2)
    duplicates = sorted(key for key, count in counts.items() if count > 1)
    return entries, duplicates


def load_tables(base_dir, problems):
    tables = {}
    if not os.path.isdir(base_dir):
        return tables
    for name in sorted(os.listdir(base_dir)):
        if not name.endswith(".lproj"):
            continue
        path = os.path.join(base_dir, name, "Localizable.strings")
        if os.path.isfile(path):
            entries, duplicates = parse_strings(path)
            if duplicates:
                problems.append(
                    f"{os.path.join(base_dir, name)}: 重复定义的 key（后一条静默生效）："
                    f"{', '.join(duplicates[:5])}"
                )
            tables[name] = entries
    return tables


def placeholders(value):
    return [(m.group(1), m.group(2)) for m in PLACEHOLDER.finditer(value)]


def collect_usage(roots, pattern):
    used = {}
    for path in swift_files(roots):
        code = strip_comments(io.open(path, encoding="utf-8").read())
        for match in pattern.finditer(code):
            used.setdefault(match.group(1), set()).add(
                os.path.relpath(path).replace("\\", "/")
            )
    return used


def check_table(label, tables, used, problems, check_format_arguments=False):
    if not tables:
        problems.append(f"{label}：没有找到任何 Localizable.strings")
        return set()

    union = set()
    for entries in tables.values():
        union |= set(entries)

    for name, entries in sorted(tables.items()):
        missing = sorted(union - set(entries))
        if missing:
            problems.append(
                f"{label}/{name}: 缺少 {len(missing)} 个 key（如 {', '.join(missing[:5])}）"
            )

    # 占位符一致性
    signatures = {}
    for name, entries in sorted(tables.items()):
        for key, value in entries.items():
            signature = tuple(placeholders(value))
            signatures.setdefault(key, []).append((name, signature))
    for key, samples in sorted(signatures.items()):
        if len(samples) < 2:
            continue
        if len({signature for _, signature in samples}) > 1:
            detail = "，".join(
                f"{name}：{'无占位符' if not sig else '…'.join(kind for _, kind in sig)}"
                for name, sig in samples
            )
            problems.append(f"{label}：`{key}` 各语言占位符不一致（{detail}）")

    for key, files in sorted(used.items()):
        if key not in union:
            problems.append(f"{label}：代码使用了未定义的 key `{key}`（{', '.join(sorted(files))}）")

    for key in sorted(union - set(used)):
        problems.append(f"{label}：定义了但代码从未引用的 key `{key}`（死文案）")

    if check_format_arguments:
        reference = tables[sorted(tables)[0]]
        for key, files in sorted(used.items()):
            value = reference.get(key)
            if value is None:
                continue
            count = len(placeholders(value))
            if count == 0:
                continue
            for path in sorted(files):
                code = strip_comments(io.open(path, encoding="utf-8").read())
                for line, actual in format_call_arguments(code, key):
                    if actual != count:
                        problems.append(
                            f"{path}:{line} `{key}` 需要 {count} 个参数，实际传入 {actual} 个"
                        )
    return union


def check_test_literals(problems, tables):
    """
    测试不得**断言本地化文案的字面值**。

    起因（CI 实测，一轮红了 18 个用例）：文案从硬编码中文改成两张表之后，
    测试里那些 `expectThrows(AppError.invalidInput("Cookie 名称不能为空"))`
    全部失配——因为 CI 模拟器跑在英文下，生产代码解析出的是英文。

    正确写法有三种，都不依赖当前语言：
    1. 期望值用同一个 key 生成：`AppError.invalidInput(Copy.text("error.cookie.nameEmpty"))`
       —— 既与语言无关，又顺手把「映射到了哪个 key」钉住；
    2. 断言稳定错误码：`appError.code == "invalid_input"`；
    3. 断言「关键信息被带进去了」：`payload.contains("x")`。

    判定保守（第一版误报了一批，因此收窄两步）：

    - **只看含汉字的文案值**。表里的英文值常与枚举 rawValue 重合
      （`"Cancelled"`、`"Sources"`），而测试断言 rawValue 是完全正当的；
      这类缺陷的原始形态就是「中文硬编码」，所以只查中文。
    - **只查长度 ≥ 6 的**。短词（「连载中」「作者」）既可能是文案也可能是夹具数据，
      误报成本很高。
    另外已经用了 `L(` / `Copy.` 的行直接放过。
    """
    import glob

    values = set()
    for entries in tables.values():
        for value in entries.values():
            plain = re.sub(r"%[0-9]*[$]?[-+ #0-9.]*[@difsuxXeEgGc]", "", value)
            if not re.search(r"[\u4e00-\u9fff]", plain):
                continue
            if len(plain) >= 6:
                values.add(plain)
            # 带占位符的前缀部分也要查（测试里常只写前半句）
            head = plain.split("：")[0]
            if len(head) >= 6:
                values.add(head)

    for path in sorted(glob.glob(os.path.join("MangaTranslater", "MangaTranslaterTests", "*.swift"))):
        text = io.open(path, encoding="utf-8").read()
        for index, line in enumerate(text.split("\n"), start=1):
            stripped = line.strip()
            if stripped.startswith(("@Test(", "@Suite(", "//", "///")):
                continue
            if 'L("' in line or "Copy." in line:
                continue
            for value in values:
                if f'"{value}"' in line:
                    problems.append(
                        f"{os.path.relpath(path).replace(chr(92), '/')}:{index} "
                        f"测试断言了本地化文案的字面值（「{value}」）；改用 "
                        f'L("…")/Copy.text("…")、稳定错误码，或断言关键片段'
                    )
                    break


def main():
    problems = []
    app_tables = load_tables(APP_TABLE_DIR, problems)
    package_tables = load_tables(PACKAGE_TABLE_DIR, problems)

    app_used = collect_usage(["MangaTranslater"], APP_USAGE)
    package_used = collect_usage(["Packages"], PACKAGE_USAGE)

    app_keys = check_table("App 表", app_tables, app_used, problems, check_format_arguments=True)
    package_keys = check_table("包层表", package_tables, package_used, problems)

    combined = dict(app_tables)
    for name, entries in package_tables.items():
        combined.setdefault(name, {}).update(entries)
    check_test_literals(problems, combined)

    for key in sorted(app_keys & package_keys):
        problems.append(f"`{key}` 同时存在于 App 表与包层表（两张表不得重名）")

    total = sum(len(entries) for entries in app_tables.values()) + sum(
        len(entries) for entries in package_tables.values()
    )
    print(
        f"本地化检查：App 表 {len(app_tables)} 种语言 / 引用 {len(app_used)} 个 key；"
        f"包层表 {len(package_tables)} 种语言 / 引用 {len(package_used)} 个 key；共 {total} 条文案"
    )
    if problems:
        print("\n❌ 发现问题：")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(
        "✅ 两张表各自 key 集合一致、代码引用的 key 均已定义、占位符类型与数量匹配、"
        "无死文案、两表无重名"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
