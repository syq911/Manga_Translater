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
        "SettingsSnapshot", "ModelValidation",
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
                # 包内文件引用了别的包但既没 import 也没在 Package.swift 声明时，
                # 这里只报 import 缺失（依赖声明由 check_packages 检查）
                problems.append((relative, module, sorted(used)[:6]))

    print(f"扫描 Swift 文件：{scanned} 个")
    if problems:
        print("\n❌ 缺少 import：")
        seen = set()
        for path, module, used in problems:
            key = (path, module)
            if key in seen:
                continue
            seen.add(key)
            print(f"  {path}\n      → 需要 `import {module}`（用到了 {', '.join(used)}）")
        return 1

    print("✅ 所有文件的 import 完整")
    return 0


if __name__ == "__main__":
    sys.exit(main())
