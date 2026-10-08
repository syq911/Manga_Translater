#!/usr/bin/env python3
"""预检：成员挂错接收者（`Type.member` 里的 member 根本不在 Type 上）。

起因是一次真实踩坑：`ModelValidation.categoryNameKey(_:)` 被写成了
`LibraryCategory.categoryNameKey(_:)`——**成员名完全正确，接收者错了**。
这类错误有两个特点：

1. **只有编译器看得见**：名字长得对、拼写也对，肉眼看一遍发现不了；
2. **代价很高**：它不会在本地暴露（本机没有 Swift 工具链），
   只能烧一轮 CI（约 12 分钟）才能拿到那四行报错。

而它其实是可以离线判定的：如果 `Type.member` 里的 `member`
**恰好只声明在另一个包里类型上**，那几乎一定是接收者写错了。
本工具就只查这一种情况，宁可漏报也不误报（误报会让人不再相信预检）。

判定步骤：

1. 从 `Packages/*/Sources/` 收集「类型 → 它声明的成员名」；
2. 反向建「成员名 → 声明它的类型集合」；
3. 扫描全部 Swift 文件里的 `Type.member(` 形态（只看静态调用的写法）；
4. 当 `Type` 是已知包类型、`member` 不在它上面、
   而 `member` 只声明在**另一个**已知包类型上时报错，并给出建议。

刻意收窄的三处：

- 只认「首字母大写的接收者 + 小写成员 + 紧跟左括号」——即 `Foo.bar(…)`。
  属性访问、`foo.bar(…)`（实例）、`Self.bar(…)` 全部不看。
- 成员名在**同文件**里出现过声明就跳过（可能是本地同名类型/嵌套类型）。
- 只有当「另一个类型」**唯一**时才报：多个候选说明这是常见命名
  （`name`、`value` 之类），报出来只会是噪音。
"""

import io
import os
import re
import sys

PACKAGE_ROOT = "Packages"
SKIP_DIR_NAMES = {".build", "DerivedData", "build", ".swiftpm", "__pycache__"}

TYPE_DECL = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+|"
    r"indirect\s+|nonisolated\s+|@unchecked\s+)*"
    r"(?:class|struct|enum|actor|protocol|extension)\s+([A-Z][A-Za-z0-9_]*)"
)
MEMBER_DECL = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|"
    r"nonisolated\s+|static\s+|class\s+|mutating\s+|override\s+|"
    r"@discardableResult\s+|@MainActor\s+)*"
    r"(?:func|var|let|case)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
# `Type.member(` —— 静态调用的写法
CALL = re.compile(r"(?<![\w.])([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)\s*\(")

# 这些「成员」由语言合成或来自标准库，不参与判定
IGNORED_MEMBERS = {"init", "self", "Type", "some", "any"}


def swift_files(root):
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
        for name in sorted(files):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)


def strip_comments(text):
    """去掉行注释与块注释（保留字符串内容，成员名判定不需要精确到字符串级）。"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    lines = []
    for line in text.split("\n"):
        index = line.find("//")
        lines.append(line if index < 0 else line[:index])
    return "\n".join(lines)


def collect_package_types():
    """→ (types, members, owners)

    types: {类型名: 所在包}
    members: {类型名: {成员名}}
    owners: {成员名: {声明它的类型名}}

    **必须按花括号深度维护类型栈**：第一版只记「最后一次见到的类型」，
    于是嵌套类型（`SourceImageLoader.Configuration`）之后的成员全被挂到嵌套类型上，
    它报出的第一条「错误」就是假阳性（实测）。
    深度记账的规则很简单：类型声明那一行的 `{` 之后进入该类型，
    深度掉回去就出栈。
    """
    types = {}
    members = {}
    owners = {}
    for path in swift_files(PACKAGE_ROOT):
        relative = os.path.relpath(path).replace("\\", "/")
        package = relative.split("/")[1] if "/" in relative else "?"
        text = strip_comments(io.open(path, encoding="utf-8").read())
        stack = []      # [(类型名, 进入时的深度)]
        depth = 0
        for line in text.split("\n"):
            match = TYPE_DECL.match(line)
            if match:
                name = match.group(1)
                types.setdefault(name, package)
                members.setdefault(name, set())
                stack.append((name, depth + 1))
            elif stack:
                member = MEMBER_DECL.match(line)
                if member:
                    current = stack[-1][0]
                    name = member.group(1)
                    members[current].add(name)
                    owners.setdefault(name, set()).add(current)

            depth += line.count("{") - line.count("}")
            while stack and depth < stack[-1][1]:
                stack.pop()
    return types, members, owners


def main():
    types, members, owners = collect_package_types()
    problems = []
    for path in swift_files("."):
        relative = os.path.relpath(path).replace("\\", "/")
        raw = io.open(path, encoding="utf-8").read()
        text = strip_comments(raw)
        for match in CALL.finditer(text):
            receiver, member = match.group(1), match.group(2)
            if receiver in {"Self"} or member in IGNORED_MEMBERS:
                continue
            if receiver not in types:
                continue                      # 不是包里的类型（App 自己的类型不管）
            if member in members.get(receiver, set()):
                continue                      # 就挂在这个类型上，正常
            if re.search(r"\b(?:func|var|let|case)\s+" + re.escape(member) + r"\b", text):
                continue                      # 同文件里声明过（可能是本地同名类型）
            candidates = {owner for owner in owners.get(member, set()) if owner != receiver}
            if len(candidates) != 1:
                continue                      # 没有候选或候选太多 → 不判
            owner = next(iter(candidates))
            line = text[: match.start()].count("\n") + 1
            problems.append(
                (
                    relative,
                    f"第 {line} 行调用 `{receiver}.{member}(…)`，但 `{member}` 不声明在 "
                    f"`{receiver}` 上（它属于 `{types.get(owner, '?')}` 包的 `{owner}`）。"
                    f"请确认接收者是不是写错了",
                )
            )

    print(f"成员接收者体检：{len(types)} 个包类型、{len(owners)} 个成员名")
    if problems:
        print("\n❌ 发现问题：")
        for path, problem in problems:
            print(f"  {path}: {problem}")
        return 1
    print("✅ 未发现「成员挂错接收者」")
    return 0


if __name__ == "__main__":
    sys.exit(main())
