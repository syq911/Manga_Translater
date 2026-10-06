#!/usr/bin/env python3
"""
自测仓库与 CI 夹具的一致性检查（本地预检工具）。

`tools/make_demo_repo.py` 生成的「中性自测仓库」与测试夹具
`MangaTranslaterTests/DemoCorpus.swift` 必须是**同一份语料**：

- 生成器负责「手工联调」：本机起个 http.server，App 里走完 安装 → 浏览 → 阅读；
- 夹具负责「CI 验证」：模拟器里用同一批页面跑通整条链路。

两侧一旦分叉，就会出现「CI 全绿但手工联调打不开」这种最费解的情况——
因为 CI 验的是另一个语料。所以这里逐字比对。

比对规则（够用且稳）：

1. 两侧的**多行字符串块按出现顺序一一对应**，内容必须逐字一致
   （忽略行尾空白）。生成器里的块是模块级常量，夹具里是 `static let`，
   顺序即约定，两边文件里都写了这条说明；
2. 两侧引用的**图片文件名集合**必须一致（图片由生成器现场合成，
   夹具只需文件名对得上，内容不参与比对）。

Swift 多行字符串会按结束定界符的缩进剥掉公共前导空格，本脚本复刻同一规则。

用法：python3 tools/check_demo_repo.py
"""

import io
import os
import re
import sys

GENERATOR = "tools/make_demo_repo.py"
FIXTURE = "MangaTranslater/MangaTranslaterTests/DemoCorpus.swift"

# Swift 的多行字面量（含字典值里的）：`"""\n…\n<缩进>"""`
SWIFT_BLOCK = re.compile(r'"""\n(.*?)\n([ \t]*)"""', re.S)
IMAGE_REFERENCE = re.compile(r"img/([A-Za-z0-9._-]+\.png)")


def load_generator():
    """直接导入生成器模块（而不是正则解析它的源码）。

    语料在生成器里是 `TEXT_FILES` 这个**有序列**表，导入即可拿到
    「顺序 + 内容」，比正则可控得多，也不会因为注释或写法变化而失配。
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import make_demo_repo  # noqa: WPS433 (局部导入是有意的)

    return make_demo_repo


def normalize(text):
    return [line.rstrip() for line in text.split("\n")]


def swift_blocks(path):
    text = io.open(path, encoding="utf-8").read()
    blocks = []
    for match in SWIFT_BLOCK.finditer(text):
        body, closing_indent = match.group(1), match.group(2)
        lines = []
        for line in body.split("\n"):
            if line.startswith(closing_indent):
                lines.append(line[len(closing_indent):])
            else:
                lines.append(line.lstrip(" "))
        blocks.append(normalize("\n".join(lines)))
    return blocks


def main():
    try:
        generator = load_generator()
        generated = [normalize(text) for _, text in generator.TEXT_FILES]
        fixture = swift_blocks(FIXTURE)
    except OSError as error:
        print(f"❌ 读取失败：{error}")
        return 1

    problems = []

    if len(generated) != len(fixture):
        problems.append(
            f"文本块数量不一致：{GENERATOR} 有 {len(generated)} 个，{FIXTURE} 有 {len(fixture)} 个"
        )
    else:
        import difflib

        for index, (left, right) in enumerate(zip(generated, fixture), start=1):
            if left == right:
                continue
            diff = list(
                difflib.unified_diff(
                    left, right, fromfile=GENERATOR, tofile=FIXTURE, lineterm="", n=1
                )
            )
            head = diff[2] if len(diff) > 2 else "（内容不同）"
            problems.append(
                f"第 {index} 个文本块不一致（{len(left)} 行 vs {len(right)} 行）：{head.strip()}"
            )

    # 图片文件名集合：生成器直接给清单，夹具侧从引用里抓
    generated_images = {name.split("/")[-1] for name, _, _ in generator.IMAGE_FILES}
    fixture_images = set(IMAGE_REFERENCE.findall(io.open(FIXTURE, encoding="utf-8").read()))
    if generated_images != fixture_images:
        only_generator = sorted(generated_images - fixture_images)
        only_fixture = sorted(fixture_images - generated_images)
        if only_generator:
            problems.append(f"生成器引用了夹具没有的图片：{', '.join(only_generator)}")
        if only_fixture:
            problems.append(f"夹具引用了生成器没有的图片：{', '.join(only_fixture)}")

    if problems:
        print("❌ 自测仓库与夹具不同步：")
        for problem in problems:
            print("  -", problem)
        print("\n修复：改生成器后，同步改夹具（或反之）；两侧必须逐字一致。")
        return 1

    print(
        f"✅ 自测仓库语料与夹具一致（{len(generated)} 个文本块、{len(generated_images)} 张图片）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
