#!/usr/bin/env python3
"""
自测仓库生成器（开发/联调用）。

生成一个**完全中性**的静态「漫画站」+ 一份配套源脚本，供本机验证整条链路：

    添加仓库 → 拉 index.json → 安装源 → 热门/搜索 → 详情 → 章节 → 阅读

用途与边界（重要）：

1. **不内置任何真实站点**：页面、图片、数据全部由本脚本现场生成；
2. **生成物不得进入仓库**：默认输出到系统临时目录；若指定到仓库内部会直接拒绝
   （源脚本 `*.js` 严禁提交，`tools/check_redlines.py` 会拦，但更该在这里就挡住）；
3. **内容与 CI 夹具同源**：本文件里的 10 个文本块（index.json、demo.js、8 个页面）
   与 `MangaTranslaterTests/DemoCorpus.swift` **逐字一致**，由
   `tools/check_demo_repo.py` 在推送前逐块比对。改这里就必须同步改夹具（或反之），
   这样「手工联调用的仓库」与「CI 验证过的语料」永远是同一份东西。

用法：

    python3 tools/make_demo_repo.py                 # 生成到系统临时目录并打印路径
    python3 tools/make_demo_repo.py --out /tmp/repo # 指定输出目录
    cd /tmp/repo && python3 -m http.server 8000     # 托管（脚本里 baseUrl 即此端口）
    # App → 浏览 → 管理源仓库 → 添加 http://127.0.0.1:8000/ → 安装 demo

    python3 tools/make_demo_repo.py --check /tmp/repo   # 校验已生成的仓库

为保持文本块顺序稳定，下列常量**按顺序**声明，`check_demo_repo.py` 依赖这个顺序。
"""

import argparse
import base64
import json
import os
import re
import struct
import sys
import tempfile
import zlib

BLOCK_ORDER_HINT = "10 个文本块，顺序即比对顺序：index.json / demo.js / 8 个页面"

INDEX_JSON = """[
  {
    "name": "Demo Source",
    "fileName": "demo.js",
    "key": "demo",
    "version": "1.0.0",
    "description": "本机联调用中性示例源（由 tools/make_demo_repo.py 生成）"
  }
]
"""

DEMO_SOURCE_JS = """// demo.js —— 中性自测源。仅供本机联调，不含任何真实站点。
// 与 tools/make_demo_repo.py 生成的静态页面配套使用。
const source = {
  id: "demo",
  name: "Demo Source",
  lang: "all",
  baseUrl: "http://127.0.0.1:8000",
  nsfw: false,
  version: "1.0.0",
  rateLimitMs: 0
};

// 列表页结构一致，抽出来复用
function items(doc) {
  return doc.select("article.item").map(function (node) {
    return {
      title: node.select("a.title").text(),
      coverUrl: node.select("img.cover").attr("src"),
      url: node.select("a.title").attr("href")
    };
  });
}

async function getPopularManga(page) {
  const res = await net.get(source.baseUrl + "/popular-" + page + ".html");
  const doc = html.parse(res.body);
  return { mangas: items(doc), hasNextPage: doc.select("a.next").length > 0 };
}

async function getLatestUpdates(page) {
  const res = await net.get(source.baseUrl + "/latest-" + page + ".html");
  const doc = html.parse(res.body);
  return { mangas: items(doc), hasNextPage: doc.select("a.next").length > 0 };
}

async function getSearchManga(page, query, filters) {
  const url = source.baseUrl + "/search.html?q=" + encodeURIComponent(query) + "&page=" + page;
  const res = await net.get(url);
  const doc = html.parse(res.body);
  return { mangas: items(doc), hasNextPage: false };
}

async function getMangaDetails(mangaUrl) {
  const res = await net.get(mangaUrl);
  const doc = html.parse(res.body);
  return {
    title: doc.select("h1.title").text(),
    author: doc.select("span.author").text(),
    artist: doc.select("span.artist").text(),
    description: doc.select("div.summary").text(),
    genres: doc.select("span.genre").map(function (node) { return node.text(); }),
    status: doc.select("span.status").text(),
    coverUrl: doc.select("img.cover").attr("src")
  };
}

async function getChapterList(mangaUrl) {
  const res = await net.get(mangaUrl);
  const doc = html.parse(res.body);
  return doc.select("ul.chapters li").map(function (node) {
    return {
      name: node.select("a").text(),
      url: node.select("a").attr("href"),
      chapterNumber: node.attr("data-number"),
      dateUpload: node.attr("data-date")
    };
  });
}

async function getPageList(chapterUrl) {
  const res = await net.get(chapterUrl);
  const doc = html.parse(res.body);
  return doc.select("div.pages img").map(function (node) {
    return node.attr("data-src");
  });
}

function getFilters() {
  return [
    { type: "text", key: "author", name: "作者" },
    {
      type: "select",
      key: "genre",
      name: "分类",
      options: [
        { label: "全部", value: "" },
        { label: "冒险", value: "adventure" }
      ]
    }
  ];
}
"""

PAGE_POPULAR_1 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo · Popular (page 1)</title></head>
<body>
<h1>Popular (page 1)</h1>
<article class="item">
  <a class="title" href="/manga-1.html">Demo Manga One</a>
  <img class="cover" src="/img/cover-1.png" alt="cover">
  <span class="author">Demo Author</span>
</article>
<article class="item">
  <a class="title" href="/manga-2.html">Demo Manga Two</a>
  <img class="cover" src="/img/cover-2.png" alt="cover">
  <span class="author">Demo Author</span>
</article>
<a class="next" href="/popular-2.html">Next page</a>
</body>
</html>
"""

PAGE_POPULAR_2 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo · Popular (page 2)</title></head>
<body>
<h1>Popular (page 2)</h1>
<article class="item">
  <a class="title" href="/manga-2.html">Demo Manga Two</a>
  <img class="cover" src="/img/cover-2.png" alt="cover">
  <span class="author">Demo Author</span>
</article>
</body>
</html>
"""

PAGE_LATEST_1 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo · Latest (page 1)</title></head>
<body>
<h1>Latest (page 1)</h1>
<article class="item">
  <a class="title" href="/manga-1.html">Demo Manga One</a>
  <img class="cover" src="/img/cover-1.png" alt="cover">
  <span class="author">Demo Author</span>
</article>
</body>
</html>
"""

PAGE_SEARCH = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo · Search</title></head>
<body>
<h1>Search results</h1>
<p class="query">The query string is accepted but ignored by this static demo.</p>
<article class="item">
  <a class="title" href="/manga-1.html">Demo Manga One</a>
  <img class="cover" src="/img/cover-1.png" alt="cover">
  <span class="author">Demo Author</span>
</article>
<article class="item">
  <a class="title" href="/manga-2.html">Demo Manga Two</a>
  <img class="cover" src="/img/cover-2.png" alt="cover">
  <span class="author">Demo Author</span>
</article>
</body>
</html>
"""

PAGE_MANGA_1 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo Manga One</title></head>
<body>
<h1 class="title">Demo Manga One</h1>
<img class="cover" src="/img/cover-1.png" alt="cover">
<span class="author">Demo Author</span>
<span class="artist">Demo Artist</span>
<span class="status">ongoing</span>
<div class="summary">A neutral sample title used to exercise the reader end to end.</div>
<span class="genre">Adventure</span>
<span class="genre">Comedy</span>
<ul class="chapters">
  <li data-number="1" data-date="2024-01-02T03:04:05Z"><a href="/chapter-1.html">Chapter 1</a></li>
  <li data-number="2" data-date="2024-02-03"><a href="/chapter-2.html">Chapter 2</a></li>
</ul>
</body>
</html>
"""

PAGE_MANGA_2 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo Manga Two</title></head>
<body>
<h1 class="title">Demo Manga Two</h1>
<img class="cover" src="/img/cover-2.png" alt="cover">
<span class="author">Demo Author</span>
<span class="artist">Demo Artist</span>
<span class="status">completed</span>
<div class="summary">A second neutral sample title, used to verify per-title details.</div>
<span class="genre">Comedy</span>
<ul class="chapters">
  <li data-number="1" data-date="2023-12-31"><a href="/chapter-2.html">Chapter 1</a></li>
</ul>
</body>
</html>
"""

PAGE_CHAPTER_1 = PAGE_CHAPTER_1 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo Manga One · Chapter 1</title></head>
<body>
<h1>Chapter 1</h1>
<div class="pages">
  <img data-src="/img/page-1.png" alt="page 1">
  <img data-src="/img/page-2.png" alt="page 2">
</div>
</body>
</html>
"""

PAGE_CHAPTER_2 = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo Manga One · Chapter 2</title></head>
<body>
<h1>Chapter 2</h1>
<div class="pages">
  <img data-src="/img/page-3.png" alt="page 3">
</div>
</body>
</html>
"""

# 文本块（顺序固定，勿调整；`tools/check_demo_repo.py` 按此顺序逐块比对）
TEXT_FILES = [
    ("index.json", INDEX_JSON),
    ("demo.js", DEMO_SOURCE_JS),
    ("popular-1.html", PAGE_POPULAR_1),
    ("popular-2.html", PAGE_POPULAR_2),
    ("latest-1.html", PAGE_LATEST_1),
    ("search.html", PAGE_SEARCH),
    ("manga-1.html", PAGE_MANGA_1),
    ("manga-2.html", PAGE_MANGA_2),
    ("chapter-1.html", PAGE_CHAPTER_1),
    ("chapter-2.html", PAGE_CHAPTER_2),
]

# 图片：现场生成，不入库（测试夹具只需文件名一致）
IMAGE_FILES = [
    ("img/cover-1.png", (16, 24), (0x2E, 0x74, 0xB5)),
    ("img/cover-2.png", (16, 24), (0x9C, 0x27, 0xB0)),
    ("img/page-1.png", (12, 18), (0x43, 0xA0, 0x47)),
    ("img/page-2.png", (12, 18), (0xFB, 0x8C, 0x00)),
    ("img/page-3.png", (12, 18), (0xC6, 0x28, 0x28)),
]

# 仓库根的「站点信息」页面：便于开发者用浏览器先看一眼
README_HTML = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo repository</title></head>
<body>
<h1>Demo source repository</h1>
<p>Generated by <code>tools/make_demo_repo.py</code>. Nothing here refers to a real site.</p>
<ul>
  <li><a href="/popular-1.html">popular-1.html</a></li>
  <li><a href="/manga-1.html">manga-1.html</a></li>
  <li><a href="/manga-2.html">manga-2.html</a></li>
  <li><a href="/chapter-1.html">chapter-1.html</a></li>
  <li><a href="/index.json">index.json</a></li>
</ul>
</body>
</html>
"""


def png_bytes(width: int, height: int, rgb) -> bytes:
    """生成一张纯色 PNG（不依赖 Pillow）。"""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def is_inside_repo(path: str) -> bool:
    root = os.path.realpath(repo_root())
    target = os.path.realpath(path)
    return target == root or target.startswith(root + os.sep)


def build(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(os.path.join(out_dir, "img"), exist_ok=True)

    for name, text in TEXT_FILES:
        with open(os.path.join(out_dir, name), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)

    with open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(README_HTML)

    for name, (width, height), rgb in IMAGE_FILES:
        with open(os.path.join(out_dir, name), "wb") as handle:
            handle.write(png_bytes(width, height, rgb))


def verify(out_dir: str) -> int:
    """对生成物做一遍「安装前静态校验」的等价检查。

    这里**故意**用 Python 复刻契约规则，而不是调用 Swift：目的是让生成器自包含，
    任何人（包括没有 Xcode 的环境）都能确认生成的源至少能过静态校验。
    真正的校验仍由 App 侧完成（`SourceScriptValidator`），CI 夹具测试也会跑一遍。
    """
    problems = []

    script_path = os.path.join(out_dir, "demo.js")
    if not os.path.isfile(script_path):
        problems.append("缺少 demo.js")
        script = ""
    else:
        script = open(script_path, encoding="utf-8").read()

    if script:
        if len(script.encode("utf-8")) > 512 * 1024:
            problems.append("脚本超过 512 KB")
        if "\x00" in script:
            problems.append("脚本包含空字节")
        for api in ("eval(", "Function(", "WebAssembly", "import(", "require("):
            if api in script:
                problems.append(f"脚本出现禁用 API：{api}")
        if "const source = {" not in script:
            problems.append("缺少 source 元信息块")
        for method in (
            "getPopularManga",
            "getSearchManga",
            "getMangaDetails",
            "getChapterList",
            "getPageList",
        ):
            if f"function {method}(" not in script:
                problems.append(f"缺少必需方法：{method}")

    index_path = os.path.join(out_dir, "index.json")
    if not os.path.isfile(index_path):
        problems.append("缺少 index.json")
    else:
        try:
            entries = json.load(open(index_path, encoding="utf-8"))
        except ValueError as error:
            problems.append(f"index.json 不是合法 JSON：{error}")
            entries = []
        for entry in entries:
            for field in ("name", "fileName", "key", "version"):
                if not entry.get(field):
                    problems.append(f"index.json 条目缺少字段：{field}")

    expected_images = {name for name, _, _ in IMAGE_FILES}
    for name in sorted(expected_images):
        if not os.path.isfile(os.path.join(out_dir, name)):
            problems.append(f"缺少图片：{name}")

    # 页面里引用到的资源都要存在，否则联调时会遇到莫名其妙的 404
    for name, _ in TEXT_FILES:
        if not name.endswith(".html"):
            continue
        text = open(os.path.join(out_dir, name), encoding="utf-8").read()
        for reference in re.findall(r'(?:href|src)="(/[^"]+)"', text):
            relative = reference.lstrip("/")
            if not os.path.isfile(os.path.join(out_dir, relative)):
                problems.append(f"{name} 引用了不存在的资源：{reference}")

    if problems:
        print("❌ 生成物自检未通过：")
        for problem in problems:
            print("  -", problem)
        return 1
    print(f"✅ 生成物自检通过：{len(TEXT_FILES)} 个文本文件 + {len(IMAGE_FILES)} 张图片")
    return 0


SWIFT_HEADER_LINES = [
    "//",
    "//  DemoCorpus.swift",
    "//  MangaTranslaterTests",
    "//",
    "//  自测仓库语料：**由 tools/make_demo_repo.py --emit-swift 生成，请勿手改**。",
    "//",
    "//  为什么单独一个文件：这套页面既是「手工联调用的自测仓库」的内容，",
    "//  也是 CI 里跑通「仓库 → 安装 → 浏览 → 详情 → 章节 → 阅读」的语料。",
    "//  两侧必须逐字一致，由 tools/check_demo_repo.py 在推送前逐块比对。",
    "//",
    "//  块顺序固定（与生成器一致）：index.json / demo.js / 8 个页面。",
    "//",
    "",
    "import Foundation",
    "",
    "enum DemoCorpus {",
    "",
    "    /// 托管地址（与 demo.js 里的 baseUrl 一致）。",
    '    static let baseURL = "http://127.0.0.1:8000"',
    "",
    "    /// 夹具用的真实 PNG 字节（内容不参与与生成器的比对，只需是合法图片）。",
    "    static let pngBytes = Data(base64Encoded: @PNG@)!",
    "",
    "    /// 页面文件名（顺序与生成器一致）。",
    "    static let pageNames = [",
    "@PAGENAMES@",
    "    ]",
    "",
    "    /// 生成器里同名常量的逐字副本（顺序即比对顺序，勿调整）。",
]

TRIPLE = '"' * 3


def swift_literal(name: str, text: str, declaration: str, separator: str = " = ") -> str:
    """把一个文本块写成语义等价的 Swift 多行字符串字面量。

    `separator` 让同一段代码既用于 `static let x = 三引号…`，
    也用于字典项 `"a.html": 三引号…`。
    """
    if TRIPLE in text:
        raise SystemExit(f"❌ {name} 含有三引号，无法写进 Swift 多行字符串")
    if "\\(" in text:
        raise SystemExit(f"❌ {name} 含有 Swift 字符串插值起始序列，需要转义")
    if "\\" in text:
        raise SystemExit(f"❌ {name} 含有反斜杠，需要转义")
    body = "\n".join("    " + line if line else "" for line in text.split("\n"))
    return f"{declaration}{separator}{TRIPLE}\n{body}\n    {TRIPLE}\n"


def emit_swift(path: str) -> None:
    """把语料写进 Swift 夹具（避免手抄出错）。"""
    pages = [(name, text) for name, text in TEXT_FILES if name not in ("index.json", "demo.js")]
    header = "\n".join(
        line
        .replace("@PNG@", base64.b64encode(png_bytes(12, 18, (0x43, 0xA0, 0x47))).decode())
        .replace("@PAGENAMES@", "\n".join(f'        "{name}",' for name, _ in pages))
        for line in SWIFT_HEADER_LINES
    )

    parts = [header, "\n"]
    parts.append(swift_literal("index.json", INDEX_JSON, "    static let indexJSON"))
    parts.append("\n")
    parts.append(swift_literal("demo.js", DEMO_SOURCE_JS, "    static let sourceScript"))
    parts.append("\n")
    parts.append("    /// 页面：文件名 → 内容（顺序与生成器一致）。\n")
    parts.append("    static let pages: [String: String] = [\n")
    for index, (name, text) in enumerate(pages):
        literal = swift_literal(name, text, f'        "{name}"', separator=": ")
        if index < len(pages) - 1:
            # 字典项之间要有逗号；字面量以收尾换行结束，因此先去掉再补 `,`
            literal = literal[:-1] + ",\n"
        parts.append(literal)
    parts.append("    ]\n")
    parts.append("}\n")

    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("".join(parts))
    print(f"✅ 已写入 Swift 夹具：{path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="生成本机联调用中性自测仓库")
    parser.add_argument("--out", help="输出目录（默认：系统临时目录下的 mangatranslater-demo-repo）")
    parser.add_argument("--check", help="只校验已生成的目录，不重新生成")
    parser.add_argument("--emit-swift", dest="emit_swift_path", help="把语料写进 Swift 夹具并退出")
    parser.add_argument(
        "--allow-in-repo",
        action="store_true",
        help="允许输出到仓库内部（默认拒绝：源脚本严禁提交）",
    )
    args = parser.parse_args()

    if args.emit_swift_path:
        emit_swift(args.emit_swift_path)
        return 0

    if args.check:
        return verify(args.check)

    out_dir = args.out or os.path.join(tempfile.gettempdir(), "mangatranslater-demo-repo")
    out_dir = os.path.abspath(out_dir)

    if is_inside_repo(out_dir) and not args.allow_in_repo:
        print("❌ 拒绝把生成物写进仓库目录：源脚本（*.js）严禁提交。", file=sys.stderr)
        print(f"   目标目录：{out_dir}", file=sys.stderr)
        print("   换成系统临时目录即可（默认行为），确需写进仓库请加 --allow-in-repo。", file=sys.stderr)
        return 2

    build(out_dir)
    status = verify(out_dir)
    print(f"\n仓库已生成：{out_dir}")
    print("托管并试用：")
    print(f"    cd {out_dir} && python3 -m http.server 8000")
    print("    App → 浏览 → 管理源仓库 → 添加 http://127.0.0.1:8000/ → 安装 demo")
    print(f"\n（{BLOCK_ORDER_HINT}）")
    return status


if __name__ == "__main__":
    sys.exit(main())
