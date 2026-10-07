#!/usr/bin/env python3
"""
官网静态站生成与校验（本工具同时是「生成器」和「预检项」）。

## 为什么官网要由脚本生成

官网有三份法务页面（隐私政策 / 使用条款 / 开源许可），它们的内容**必须**与
App 内置副本一致。人工维护三份副本（`docs/legal/*.md` → App Swift 常量 → 官网 HTML）
一定会分叉，而分叉在法务文本上等于对用户误导。

因此这里坚持「一个来源」：

    docs/legal/*.md  ──(check_legal_sync.py --emit)──→  App 内置副本
                     └─(build_website.py)────────────→  website/*.html

其余页面（首页、升级页）是手写的静态 HTML，本脚本负责**校验**它们：
相对链接是否都存在、是否引用了外部资源（官网必须能离线打开、不依赖 CDN）、
是否缺少语言切换标记。

用法：
    python3 tools/build_website.py            # 生成 + 校验
    python3 tools/build_website.py --check    # 只校验（CI/预检用）
"""

import io
import os
import re
import sys

DOCS_DIR = os.path.join("docs", "legal")
SITE_DIR = "website"

# 法务页面：输出文件名 → [(语言, 源 Markdown, 锚点标题)]
LEGAL_PAGES = {
    "privacy.html": [
        ("en", "privacy.en.md"),
        ("zh-Hans", "privacy.zh-Hans.md"),
    ],
    "terms.html": [
        ("en", "terms.en.md"),
        ("zh-Hans", "terms.zh-Hans.md"),
    ],
    "licenses.html": [
        ("en", "licenses.en.md"),
        ("zh-Hans", "licenses.zh-Hans.md"),
    ],
}

PAGE_TITLES = {
    "privacy.html": ("Privacy policy", "隐私政策"),
    "terms.html": ("Terms of use", "使用条款"),
    "licenses.html": ("Licences", "开源许可"),
}

# 上线后必须替换的占位符（check 会提示，但不作为失败——它们本来就该由人来填）
PLACEHOLDERS = ["REPLACE-ME", "example.com", "example.org", "TODO"]

NAV = [
    ("index.html", "Home", "首页"),
    ("upgrade.html", "Pricing", "定价"),
    ("privacy.html", "Privacy", "隐私"),
    ("terms.html", "Terms", "条款"),
]


def shell(title_en, title_zh, body, active="", description=""):
    """
    页面外壳：head + 顶栏 + 正文 + 页脚。

    刻意**不引入任何外部资源**（无 CDN、无字体、无统计脚本）：
    官网要能在离线、在没有第三方的情况下打开，这既是可用性也是合规姿态
    （不把访客的浏览行为送给任何第三方）。
    """
    nav_items = []
    for href, en, zh in NAV:
        classes = ' class="active"' if href == active else ""
        nav_items.append(
            f'<a href="{href}"{classes}><span data-lang="en">{en}</span>'
            f'<span data-lang="zh-Hans">{zh}</span></a>'
        )
    nav = "\n        ".join(nav_items)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title_en} · MangaTranslater</title>
<meta name="description" content="{description}">
<script>
// 语言：优先跟随浏览器，其次英文。写在 head 里、CSS 之前，避免刷新时闪一下双语。
document.documentElement.dataset.lang =
  (navigator.language || 'en').toLowerCase().startsWith('zh') ? 'zh-Hans' : 'en';
</script>
<link rel="stylesheet" href="assets/site.css">
</head>
<body>
<header class="topbar">
  <a class="brand" href="index.html">MangaTranslater</a>
  <nav>
        {nav}
  </nav>
  <button id="lang-toggle" type="button" aria-label="Switch language">EN / 中文</button>
</header>
<main>
{body}
</main>
<footer class="footer">
  <p>
    <span data-lang="en">MangaTranslater is a general-purpose comic reader. It ships with no online
    sources and no third-party content.</span>
    <span data-lang="zh-Hans">MangaTranslater 是通用漫画阅读器，不自带任何在线源，也不包含任何第三方内容。</span>
  </p>
  <p class="dim">
    <a href="privacy.html"><span data-lang="en">Privacy</span><span data-lang="zh-Hans">隐私政策</span></a> ·
    <a href="terms.html"><span data-lang="en">Terms</span><span data-lang="zh-Hans">使用条款</span></a> ·
    <a href="licenses.html"><span data-lang="en">Licences</span><span data-lang="zh-Hans">开源许可</span></a> ·
    <a href="https://github.com/syq911/Manga_Translater">GitHub</a>
  </p>
  <h1 class="visually-hidden">{title_en}</h1>
</footer>
<script src="assets/site.js"></script>
</body>
</html>
"""


# MARK: - 极简 Markdown → HTML


def inline(text):
    """行内标记：`code`、**bold**、[label](url)。"""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    def code(match):
        return f"<code>{match.group(1)}</code>"

    text = re.sub(r"`([^`]+)`", code, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)

    def email(match):
        # 邮箱在纯文本里出现时做成可点链接：法务页面最需要的动作就是写信
        return f'<a href="mailto:{match.group(1)}">{match.group(1)}</a>'

    text = re.sub(r"(?<![\w/>])([\w.+-]+@[\w-]+\.[\w.-]+)", email, text)
    return text


def markdown_to_html(markdown):
    """把法务 Markdown 转成 HTML。只覆盖法务文本实际用到的结构。"""
    lines = markdown.replace("\r\n", "\n").split("\n")
    html = []
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if stripped.startswith("```"):
            block = []
            index += 1
            while index < len(lines) and not lines[index].strip().startswith("```"):
                block.append(lines[index])
                index += 1
            index += 1
            html.append("<pre><code>" + "\n".join(block).replace("&", "&amp;").replace("<", "&lt;")
                        .replace(">", "&gt;") + "</code></pre>")
            continue

        if not stripped:
            index += 1
            continue

        if stripped.startswith("|") and index + 1 < len(lines) and is_separator(lines[index + 1]):
            rows = []
            index += 1  # 表头
            index += 1  # 分隔行
            while index < len(lines) and lines[index].strip().startswith("|"):
                rows.append([cell.strip() for cell in split_row(lines[index])])
                index += 1
            html.append("<table>")
            for row in rows:
                cells = "".join(f"<td>{inline(cell)}</td>" for cell in row)
                html.append(f"<tr>{cells}</tr>")
            html.append("</table>")
            continue

        if stripped.startswith("### "):
            html.append(f'<h3 id="{slug(stripped[4:])}">{inline(stripped[4:])}</h3>')
            index += 1
            continue
        if stripped.startswith("## "):
            html.append(f'<h2 id="{slug(stripped[3:])}">{inline(stripped[3:])}</h2>')
            index += 1
            continue
        if stripped.startswith("# "):
            html.append(f'<h1 id="{slug(stripped[2:])}">{inline(stripped[2:])}</h1>')
            index += 1
            continue

        if stripped.startswith("- "):
            items = []
            while index < len(lines) and lines[index].strip().startswith("- "):
                items.append(f"<li>{inline(lines[index].strip()[2:])}</li>")
                index += 1
            html.append("<ul>" + "".join(items) + "</ul>")
            continue

        if re.match(r"^\d+\.\s", stripped):
            items = []
            while index < len(lines) and re.match(r"^\d+\.\s", lines[index].strip()):
                item = re.sub(r"^\d+\.\s", "", lines[index].strip())
                items.append(f"<li>{inline(item)}</li>")
                index += 1
            html.append("<ol>" + "".join(items) + "</ol>")
            continue

        if stripped == "---":
            html.append("<hr>")
            index += 1
            continue

        html.append(f"<p>{inline(stripped)}</p>")
        index += 1

    return "\n".join(html)


def is_separator(line):
    stripped = line.strip()
    if not stripped.startswith("|"):
        return False
    body = stripped.replace("|", "").replace("-", "").replace(":", "").replace(" ", "")
    return body == ""


def split_row(line):
    cells = line.strip().split("|")
    if cells and not cells[0].strip():
        cells = cells[1:]
    if cells and not cells[-1].strip():
        cells = cells[:-1]
    return cells


def slug(text):
    slugged = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "-", text.lower()).strip("-")
    return slugged or "section"


# MARK: - 生成


def build_legal_page(file_name):
    title_en, title_zh = PAGE_TITLES[file_name]
    sections = []
    for language, source in LEGAL_PAGES[file_name]:
        path = os.path.join(DOCS_DIR, source)
        markdown = io.open(path, encoding="utf-8").read()
        body = markdown_to_html(markdown)
        sections.append(
            f'<article class="legal" data-lang="{language}">\n{body}\n</article>'
        )
    body = (
        '<div class="container narrow">\n'
        f'<p class="kicker"><span data-lang="en">{title_en}</span>'
        f'<span data-lang="zh-Hans">{title_zh}</span></p>\n'
        + "\n".join(sections)
        + "\n</div>"
    )
    return shell(title_en, title_zh, body, active=file_name,
                 description=f"MangaTranslater — {title_en}")


# MARK: - 校验


def site_pages():
    found = []
    for name in sorted(os.listdir(SITE_DIR)):
        if name.endswith(".html"):
            found.append(name)
    return found


def check(errors, warnings):
    pages = site_pages()
    for required in ["index.html", "upgrade.html", "privacy.html", "terms.html", "licenses.html"]:
        if required not in pages:
            errors.append(f"{SITE_DIR}/{required} 不存在")

    for name in pages:
        path = os.path.join(SITE_DIR, name)
        text = io.open(path, encoding="utf-8").read()

        if 'data-lang="zh-Hans"' not in text:
            errors.append(f"{SITE_DIR}/{name} 缺少中英双语标记（data-lang）")
        if "assets/site.css" not in text:
            errors.append(f"{SITE_DIR}/{name} 没有引用 assets/site.css")

        # 相对链接必须存在；外部资源（src=）一律不允许（官网要能离线打开）
        for match in re.finditer(r'(?:href|src)="([^"]+)"', text):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:", "#")):
                if match.group(0).startswith("src=") and target.startswith("http"):
                    errors.append(f"{SITE_DIR}/{name} 引用了外部资源：{target}")
                continue
            resolved = os.path.join(SITE_DIR, target.split("#")[0])
            if target and not os.path.exists(resolved):
                errors.append(f"{SITE_DIR}/{name} 的链接指向不存在的文件：{target}")

        for placeholder in PLACEHOLDERS:
            if placeholder in text:
                warnings.append(f"{SITE_DIR}/{name} 仍含占位符 `{placeholder}`（上线前替换）")

    for name, pairs in LEGAL_PAGES.items():
        for _, source in pairs:
            if not os.path.exists(os.path.join(DOCS_DIR, source)):
                errors.append(f"缺少法务源文件 docs/legal/{source}")


def main():
    errors = []
    warnings = []

    # 先生成、后校验：校验里有「相对链接必须存在」这一条，
    # 反过来做的话，全新克隆出来的仓库会先报一堆「法务页面不存在」的假错误。
    if "--check" not in sys.argv[1:]:
        os.makedirs(SITE_DIR, exist_ok=True)
        for name in LEGAL_PAGES:
            html = build_legal_page(name)
            io.open(os.path.join(SITE_DIR, name), "w", encoding="utf-8", newline="\n").write(html)
            print(f"✅ 生成 {SITE_DIR}/{name}")

    check(errors, warnings)

    print(f"官网页面：{len(site_pages())} 个；占位符提示 {len(warnings)} 条")
    for warning in warnings:
        print(f"  · {warning}")
    if errors:
        print("\n❌ 发现问题：")
        for error in errors:
            print("  -", error)
        return 1
    print("✅ 官网校验通过（双语标记齐备、相对链接存在、无外部资源依赖）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
