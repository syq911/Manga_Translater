#!/usr/bin/env python3
"""
导入完整性检查（本地预检工具）。

用途：在推送前发现「用到了某个包的类型，却没有 import 该模块」这类
编译器才会报的问题，避免为一个低级错误多跑一轮 CI。

用法：python3 tools/check_imports.py
退出码：0 = 无问题；1 = 发现问题（并打印需要补的 import）。
"""

import io
import os
import re
import sys

PKG_TYPES = {
    "AppCore": [
        "Manga", "Chapter", "ComicPage", "SourceID", "SourceKind", "SourceMeta",
        "LibraryEntry", "MangaStatus", "MangaListPage", "AppSettings", "AppError",
        "DiagnosticsLog", "TranslationBackend", "ReaderMode", "TranslationLanguage",
        "SettingsSnapshot", "ModelValidation", "PageDataProviding", "ReaderSession",
        "ReaderAdvanceResult", "ReaderTheme", "ZoomState",
    ],
    "ComicNet": [
        "HTTPClient", "HTTPResponse", "HTTPTransporting", "CookieJar", "StoredCookie",
        "RateLimiter", "NetworkError",
    ],
    "SourceEngine": [
        "SourceStore", "InstalledSource", "SourceFileSystem", "DefaultSourceFileSystem",
        "SourceIndexParser", "SourceIndexEntry", "SourceIndexError", "SourceScriptValidator",
        "SourceScriptMeta", "SourceScriptValidationError", "SourceAPIContract", "SourceAPIMethod",
        "SourceRunnerError", "SourceRuntimeExecuting", "SourceRuntimeConfiguration",
        "LocalSource", "LocalArchiveIndexer", "LocalChapterDescriptor", "LocalBookIndex",
        "LocalSourceError",
    ],
    "AppDatabase": [
        "LibraryStoring", "LibrarySortOrder", "ReadingHistoryEntry", "LibraryStoreError",
        "DatabaseLibraryStore", "InMemoryLibraryStore", "AppDatabase", "DatabaseLocation",
        "Migrations",
    ],
    "ComicDownload": [
        "DownloadQueue", "DownloadJob", "DownloadState", "DownloadQueueConfiguration",
        "PageFetching", "PageStoring", "FilePageStore", "InMemoryPageStore",
        "ZipArchiveWriter", "ZipArchiveReader", "ZipEntryInfo", "ZipArchiveError", "Crc32",
        "CbzExporter", "CbzPage", "CbzExportError",
    ],
}

APP_MODULES = set(PKG_TYPES)


def swift_files(root):
    found = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            if name.endswith(".swift"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def strip_comments(text):
    """去掉行注释与块注释，避免注释里的类型名造成误报。"""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(
        line for line in text.split("\n") if not line.strip().startswith("//")
    )


def owning_package(relative_path):
    parts = relative_path.replace("\\", "/").split("/")
    if parts[0] == "Packages" and len(parts) > 1:
        return parts[1]
    return None  # App target


def _collect_members():
    """
    收集「(类型名, 成员名) → 是否 public」。

    按类型归属而不是按模块归属，避免同名成员互相干扰
    （例如 `HTTPClient.transport` 是私有属性，而 `NetworkError.transport`
     是自动 public 的枚举 case —— 按模块归属会误报）。

    只统计成员层声明（缩进恰好 4 个空格），并跳过 `case`（枚举 case
    自动继承枚举访问级别，无需 public）。
    """
    members = {}
    type_pattern = re.compile(
        r"^(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
        r"(?:class|struct|enum|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"
    )

    for path in swift_files("Packages"):
        current_type = None
        for line in io.open(path, encoding="utf-8").read().split("\n"):
            indent = len(line) - len(line.lstrip(" "))
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            if indent == 0:
                match = type_pattern.match(line)
                if match:
                    current_type = match.group(1)
                elif stripped and not stripped.startswith(("@", "}", ")")):
                    # 顶层非类型声明（如全局函数）→ 脱离类型上下文
                    current_type = None
                continue
            if indent != 4 or current_type is None:
                continue
            match = re.search(r"\b(?:let|var|func|init)\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
            if not match:
                continue
            name = match.group(1)
            is_public = re.search(r"\bpublic\b", stripped) is not None
            key = (current_type, name)
            members[key] = members.get(key, False) or is_public

    return members


def check_access_levels(problems):
    """
    检查跨模块访问权限：App / 测试里 `Type.member` 形式的调用，
    对应声明必须是 public，否则会报
    "is inaccessible due to 'internal' protection level"。

    - 只在包源码里能找到声明的成员才检查；
    - 协议合成成员（allCases、rawValue、hashValue 等）跳过；
    - 枚举 case 天然可见，不参与检查；
    - 同名重载只要有一处 public 即视为可见。
    """
    type_to_module = {name: module for module, types in PKG_TYPES.items() for name in types}
    members = _collect_members()

    # 由协议合成 / 语言构造提供的成员，不参与检查
    synthesized = {
        "allCases", "rawValue", "hashValue", "description", "hash",
        "debugDescription", "localizedDescription", "errorDescription",
        "self", "Type", "init",
    }

    seen = set()
    for path in swift_files("MangaTranslater"):
        relative = os.path.relpath(path).replace("\\", "/")
        raw = io.open(path, encoding="utf-8").read()
        code = strip_comments(raw)
        # `@testable import X` 会让 X 的 internal 成员也可访问 —— 对这类模块跳过检查
        testable_modules = set(
            re.findall(r"^\s*@testable\s+import\s+([A-Za-z_][A-Za-z0-9_]*)", raw, re.M)
        )
        for match in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.([a-z][A-Za-z0-9_]*)", code):
            type_name, member = match.group(1), match.group(2)
            module = type_to_module.get(type_name)
            if module is None or member in synthesized:
                continue
            if module in testable_modules:
                continue  # @testable import 下 internal 也可见
            key = (type_name, member)
            if key not in members:
                continue  # 找不到声明 → 视为枚举 case 或协议/语言合成，跳过
            if members[key]:
                continue
            marker = (relative, type_name, member)
            if marker in seen:
                continue
            seen.add(marker)
            problems.append(
                (
                    relative,
                    f"{type_name}.{member} 在 {module} 中不是 public，跨模块访问会编译失败",
                    [member],
                )
            )


def main():
    problems = []
    scanned = 0

    for root in ("MangaTranslater", "Packages"):
        if not os.path.isdir(root):
            continue
        for path in swift_files(root):
            relative = os.path.relpath(path).replace("\\", "/")
            owner = owning_package(relative)
            text = io.open(path, encoding="utf-8").read()
            code = strip_comments(text)
            imports = set(re.findall(r"^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M))
            scanned += 1

            for module, types in PKG_TYPES.items():
                # 包内文件使用自身模块的类型不需要 import
                if owner is not None and module == owner:
                    continue
                used = [t for t in types if re.search(r"\b" + re.escape(t) + r"\b", code)]
                if not used:
                    continue
                if module in imports:
                    continue
                problems.append((relative, f"需要 import {module}", sorted(used)[:6]))

    check_access_levels(problems)

    print(f"扫描 Swift 文件：{scanned} 个")
    if problems:
        print("\n❌ 发现问题：")
        seen = set()
        for path, reason, used in problems:
            key = (path, reason)
            if key in seen:
                continue
            seen.add(key)
            detail = f"（用到了 {', '.join(used)}）" if used else ""
            print(f"  {path}\n      → {reason}{detail}")
        return 1

    print("✅ import 完整、跨模块访问权限正确")
    return 0


if __name__ == "__main__":
    sys.exit(main())
