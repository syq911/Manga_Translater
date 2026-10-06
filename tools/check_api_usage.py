#!/usr/bin/env python3
"""
构造调用与 init 声明的一致性检查（本地预检工具）。

**动机**：本机没有 Swift 编译器，而"改了某类型的 init 签名、忘了同步调用方"
是本项目实测出现过的一类错误（`AppEnvironment` 新增三个参数后，
`IntegrationTests` 里的旧调用直到 CI 才报
"missing arguments for parameters ..."）。这类问题纯靠文本即可判定。

做法：
1. 收集仓库内每个类型的 `init` 声明参数（仅当该类型**只有一个** init 时才检查，
   多 init 视为重载、跳过）；
2. 在 App 与测试代码里找 `Type(` 形式的构造调用；
3. 若调用缺少任何**没有默认值**的参数，报错。

已知刻意忽略的情况（避免误报）：
- 类型没有显式 init（走结构体逐成员合成 init）；
- 调用出现在被注释掉的代码里（注释已剥离）；
- 泛型/闭包里的嵌套括号（按深度解析参数，不误切）。

用法：python3 tools/check_api_usage.py
"""

import io
import os
import re
import sys

SKIP_DIRS = {".git", ".build", "DerivedData", "build", ".swiftpm", "__pycache__"}
# 类型声明可能带属性（`@MainActor @Observable final class Foo`），
# 也可能带访问级别与 final/open，这里统一前缀都允许。
TYPE_DECL = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
EXTENSION_DECL = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"extension\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def swift_files(*roots):
    found = []
    for root in roots:
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in files:
                if name.endswith(".swift"):
                    found.append(os.path.join(dirpath, name))
    return sorted(found)


def strip_comments(text):
    """去掉注释，但**保留行数**（把注释行换成空行）。

    早先的实现直接 `join` 掉注释行，于是后面 `enumerate` 出来的行号
    比真实文件少几行——报「第 209 行有问题」而实际在 248 行，
    等于让人再去搜一遍。检查器报错必须能直接跳过去。
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(
        "" if l.strip().startswith("//") else l for l in text.split("\n")
    )


def bracket_delta(text, index):
    """括号深度增量；`->` 里的 `>` 不算闭合。

    动机（实测踩过）：`clock: @escaping @Sendable () -> Date = { Date() }`
    这种**闭包类型默认值**里的 `->` 会被当成 `>` 闭合括号，
    深度一路变成负数，后面所有顶层逗号都不再被识别 ——
    `RateLimiter` 的 `sleeper` 参数因此整个消失，
    连带「参数顺序」「未声明标签」两条检查全部误报。
    """
    ch = text[index]
    if ch == ">" and index > 0 and text[index - 1] == "-":
        return 0          # `->` 是箭头，不是泛型闭合
    if ch in "([{<":
        return 1
    if ch in ")]}>":
        return -1
    return 0


def split_top_level(text):
    """按顶层逗号切分（忽略括号 / 方括号 / 尖括号内的逗号）。

    深度**不允许变负**。原因（实测踩过）：默认值里的闭包可以含比较运算，
    例如
        sleeper: @Sendable (Double) -> Void = { interval in
            guard interval > 0 else { return }
        }
    这里的 `>` 并不是泛型闭合，`bracket_delta` 却按 `)` 那样记 −1；
    深度一路变负之后，闭包与其后**所有**参数之间的逗号都不再被当作顶层逗号，
    于是 `chunkSize:` / `maxAttempts:` 两个参数被静默吞掉 ——
    检查器不但漏检，还会拿着残缺的参数表报出「未声明的参数标签」这种假错误。
    `<` / `>` 只在泛型实参里成对出现，把负深度夹到 0 即可：
    极端情况下顶多多切一刀（把某个参数拆开，进而在后续解析里被忽略），
    但不会再制造出「凭空多出来的标签」。
    """
    parts = []
    depth = 0
    current = ""
    for index, ch in enumerate(text):
        depth += bracket_delta(text, index)
        if depth < 0:
            depth = 0
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
            continue
        current += ch
    if current.strip():
        parts.append(current)
    return parts


def extract_paren_group(text, start):
    """从 `text[start] == '('` 起取出配对括号内的内容；返回 (内容, 结束下标)。"""
    assert text[start] == "("
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:index], index
    return None, len(text)


def parse_parameters(inner):
    """解析参数列表 → [(label, has_default)]。"""
    result = []
    for chunk in split_top_level(inner):
        piece = chunk.strip()
        if not piece:
            continue
        # 只看顶层冒号前的标签
        depth = 0
        colon_at = None
        for index, ch in enumerate(piece):
            if ch == ":" and depth == 0:
                colon_at = index
                break
            depth += bracket_delta(piece, index)
        # 有默认值判据：该参数片段里出现 `=`。
        # 不做括号深度判定 —— 默认值可能是闭包（含括号），逐字符判定容易漏，
        # 而类型表达式本身不含 `=`，所以直接查字符就足够可靠。
        has_default = "=" in piece
        if colon_at is None:
            # 无标签（如闭包参数的简写），无法判定，按有默认处理以免误报
            result.append((None, True))
            continue
        label = piece[:colon_at].strip().split()[-1] if piece[:colon_at].strip() else None
        result.append((label, has_default))
    return result


def collect_inits(files):
    """类型名 → (参数列表, 出现次数)；只保留恰好一个 init 的类型。"""
    collected = {}
    for path in files:
        text = strip_comments(io.open(path, encoding="utf-8").read())
        lines = text.split("\n")
        current_type = None
        for index, line in enumerate(lines):
            stripped = line.strip()
            if not stripped:
                continue   # 空行不得重置类型上下文（曾因此漏掉全部带属性的类型）
            if not line.startswith((" ", "\t")):
                match = TYPE_DECL.match(line) or EXTENSION_DECL.match(line)
                if match:
                    current_type = match.group(1)
                elif not stripped.startswith(("@", "}", ")", "#")):
                    current_type = None

            if "init(" not in stripped or current_type is None:
                continue

            # init 常常跨多行：逐行拼接直到括号配平
            merged = stripped
            inner, _ = extract_paren_group(merged, merged.find("init(") + len("init"))
            cursor = index + 1
            while inner is None and cursor < len(lines):
                merged += " " + lines[cursor].strip()
                cursor += 1
                inner, _ = extract_paren_group(merged, merged.find("init(") + len("init"))
            if inner is None:
                continue
            params = parse_parameters(inner)
            collected.setdefault(current_type, []).append(params)
    return {name: decls[0] for name, decls in collected.items() if len(decls) == 1}


def collect_call_labels(code, type_name):
    """找出 `TypeName(` 调用的实参标签；返回 [[按出现顺序的标签]]。

    顺序很重要：Swift 要求实参顺序与声明一致，
    `JSSourceRuntime(transport: t, configuration: c)` 会被编译器拒绝
    「argument 'configuration' must precede argument 'transport'」
    （实测踩过一轮 CI），因此这里保留顺序供后面校验。
    """
    calls = []
    for match in re.finditer(r"\b" + re.escape(type_name) + r"\s*\(", code):
        # 排除声明本身（`init(` / 类型定义行）
        prefix = code[max(0, match.start() - 6):match.start()]
        if prefix.rstrip().endswith(("func", "class", "struct", "enum", "actor", "extension")):
            continue
        inner, _ = extract_paren_group(code, match.end() - 1)
        if inner is None:
            continue
        labels = []
        for chunk in split_top_level(inner):
            piece = chunk.strip()
            depth = 0
            for index, ch in enumerate(piece):
                if ch in "([{<":
                    depth += 1
                elif ch in ")]}>":
                    depth -= 1
                elif ch == ":" and depth == 0:
                    label = piece[:index].strip()
                    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", label):
                        labels.append(label)
                    break
        calls.append(labels)
    return calls


def out_of_order(provided, declared):
    """`provided` 是否为 `declared` 的**顺序子序列**；不是则返回首个错位的标签。"""
    index = 0
    for label in provided:
        while index < len(declared) and declared[index] != label:
            index += 1
        if index == len(declared):
            return label
        index += 1
    return None


def check_app_environment_members(swift_files):
    """
    `environment.xxx` 里的 `xxx` 必须是 `AppEnvironment` 真的有的成员。

    动机（实测烧了一轮 CI）：把 AppCore 的**全局函数** `diag(...)` 写成了
    `environment.diag(...)`，编译器报 "value of type 'AppEnvironment' has no
    member 'diag'"。

    判定简单而精确：`environment` 在本项目里只有一种身份
    （`@Environment(AppEnvironment.self)`），所以只要名字不在成员表里就是错的。
    """
    path = "MangaTranslater/App/AppEnvironment.swift"
    if not os.path.exists(path):
        return []
    text = strip_comments(io.open(path, encoding="utf-8").read())

    # 成员声明：`let x` / `var x` / `func x` / `private let x` …
    member = re.compile(
        r"^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?[ \t]+)*"
        r"(?:public[ \t]+|internal[ \t]+|private\(set\)[ \t]+|private[ \t]+"
        r"|fileprivate[ \t]+|static[ \t]+|final[ \t]+)*"
        r"(?:let|var|func)[ \t]+([A-Za-z_][A-Za-z0-9_]*)",
        re.M,
    )
    members = set(member.findall(text))
    if not members:
        return []

    usage = re.compile(r"\benvironment\.([A-Za-z_][A-Za-z0-9_]*)")
    problems = []
    for file in swift_files:
        raw = strip_comments(io.open(file, encoding="utf-8").read())
        for index, line in enumerate(raw.split("\n"), start=1):
            for match in usage.finditer(line):
                name = match.group(1)
                if name in members:
                    continue
                problems.append(
                    (
                        os.path.relpath(file).replace("\\", "/"),
                        f"第 {index} 行 `environment.{name}` 不是 AppEnvironment 的成员"
                        f"（若是全局函数，直接写 `{name}(…)`）",
                    )
                )
    return problems


def check_mutating_calls_inside_expect(files):
    """
    `#expect(...)` 的参数会被宏包进闭包，闭包捕获的变量是**不可变**的，
    因此里面不能调用 `mutating` 方法（实测报"cannot use mutating member on
    immutable value: '$0' is immutable"）。

    规则：收集仓库内所有 `mutating func` 的名字，若某个 `#expect(...)` 里
    出现 `<接收者>.<该名字>(` 即报错。
    """
    mutating_names = set()
    for path in files:
        text = strip_comments(io.open(path, encoding="utf-8").read())
        mutating_names.update(re.findall(r"\bmutating\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    if not mutating_names:
        return []

    pattern = re.compile(r"#expect\([^\n]*\.(" + "|".join(sorted(mutating_names)) + r")\s*\(")
    problems = []
    for path in swift_files("MangaTranslater"):
        text = strip_comments(io.open(path, encoding="utf-8").read())
        for index, line in enumerate(text.split("\n"), start=1):
            match = pattern.search(line)
            if match:
                problems.append(
                    (
                        os.path.relpath(path).replace("\\", "/"),
                        f"第 {index} 行的 #expect 里调用了 mutating 方法 {match.group(1)}()，"
                        "应先调用取返回值再断言",
                    )
                )
    return problems


def main():
    library_files = swift_files("Packages")
    consumer_files = swift_files("MangaTranslater")

    inits = collect_inits(library_files + consumer_files)
    if not inits:
        print("未收集到可检查的 init 声明")
        return 0

    problems = []
    checked = 0
    for path in consumer_files:
        code = strip_comments(io.open(path, encoding="utf-8").read())
        for type_name, params in inits.items():
            required = {label for label, has_default in params if label and not has_default}
            declared_order = [label for label, _ in params if label]
            for labels in collect_call_labels(code, type_name):
                checked += 1
                relative = os.path.relpath(path).replace("\\", "/")
                # 写错的标签名（拼错 / 记错）在 Swift 里是编译错误，
                # 而它既不属于「缺少必需参数」也过得了顺序检查——单独报出来。
                # `collect_inits` 只保留**唯一 init** 的类型，所以这里不会因重载误报。
                unknown = [label for label in labels if label not in declared_order]
                if unknown:
                    problems.append(
                        (
                            relative,
                            f"{type_name}(...) 出现未声明的参数标签：{', '.join(unknown)}；"
                            f"可用标签为 ({', '.join(declared_order)})",
                        )
                    )
                missing = required - set(labels)
                if missing:
                    problems.append(
                        (
                            relative,
                            f"{type_name}(...) 缺少必需参数：{', '.join(sorted(missing))}",
                        )
                    )
                # 顺序也要对：Swift 不允许「声明是 a,b 却写成 b,a」
                misplaced = out_of_order(labels, declared_order)
                if misplaced:
                    problems.append(
                        (
                            relative,
                            f"{type_name}(...) 参数顺序与声明不符：实参以 `{misplaced}` 出现在 "
                            f"不应该的位置；声明顺序为 ({', '.join(declared_order)})",
                        )
                    )

    for path, message in check_mutating_calls_inside_expect(library_files + consumer_files):
        problems.append((path, message))

    for path, message in check_app_environment_members(consumer_files):
        problems.append((path, message))

    print(f"检查构造调用：{checked} 处（涉及 {len(inits)} 个类型）")
    if problems:
        print("\n❌ 发现问题：")
        seen = set()
        for path, message in problems:
            key = (path, message)
            if key in seen:
                continue
            seen.add(key)
            print(f"  {path}: {message}")
        return 1
    print("✅ 构造调用的参数与 init 声明一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
