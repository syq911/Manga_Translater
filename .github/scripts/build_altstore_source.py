#!/usr/bin/env python3
"""
从 GitHub Releases 生成 AltStore / SideStore 的源清单 (source.json)。

背景：iOS 不允许下载并执行原生代码（内核层强制代码签名），所以这个 App
没有真正的热更新。能做到「装一次之后自动更新」的是 AltStore / SideStore 的
源订阅——用户添加一次源，之后新版本会出现在它们的更新列表里，
用用户自己的证书重签安装，不需要再来 GitHub 手动下载。

这个脚本在每次发布后重新生成清单，把全部历史版本都列进去：
AltStore 需要看到完整的 versions 数组才能判断「有没有比本机更新的版本」，
只放最新一条会让降级和跳版判断失效。

清单托管方式：作为每个 Release 的附件上传，对外统一地址为
  https://github.com/<owner>/<repo>/releases/latest/download/source.json
（releases/latest 永远指向最新正式发布，因此该地址内容随版本自动更新）。
"""

import io
import json
import os
import plistlib
import sys
import urllib.request
import zipfile

REPO = os.environ.get("GITHUB_REPOSITORY", "syq911/Manga_Translater")
BUNDLE_ID = "com.mangatranslater.ios"
SOURCE_IDENTIFIER = "com.mangatranslater.source"
SOURCE_NAME = "MangaTranslater"
DEVELOPER = "MangaTranslater"
FALLBACK_MIN_OS = "18.0"


def _token():
    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")


def fetch_releases():
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/releases?per_page=100",
        headers={"Accept": "application/vnd.github+json"},
    )
    token = _token()
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


# AltStore / SideStore 用 minOSVersion 判断能否装到当前设备，填错就装不上。
# 这个值随版本变，所以直接从 ipa 的 Info.plist 里读，而不是写死一个常量。
def min_os_version(ipa_url):
    """从 ipa 内 Payload/*.app/Info.plist 读 MinimumOSVersion。"""
    try:
        req = urllib.request.Request(ipa_url)
        token = _token()
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=120) as r:
            blob = r.read()
        with zipfile.ZipFile(io.BytesIO(blob)) as z:
            name = next(
                (
                    n
                    for n in z.namelist()
                    if n.startswith("Payload/")
                    and n.endswith(".app/Info.plist")
                    and n.count("/") == 2
                ),
                None,
            )
            if not name:
                raise LookupError("ipa 内找不到 Payload/*.app/Info.plist")
            value = plistlib.loads(z.read(name)).get("MinimumOSVersion")
            if not value:
                raise LookupError("Info.plist 中没有 MinimumOSVersion")
            return str(value)
    except Exception as exc:  # noqa: BLE001 —— 单个版本读失败不该让整个清单挂掉
        print(f"⚠️  读取 {ipa_url} 的 MinimumOSVersion 失败({exc})，回退 {FALLBACK_MIN_OS}", file=sys.stderr)
        return FALLBACK_MIN_OS


def build_versions(releases):
    versions = []
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        ipa = next(
            (a for a in rel.get("assets", []) if a["name"].endswith(".ipa")), None
        )
        if not ipa:
            # 没有 ipa 的发布跳过——AltStore 只认 ipa
            continue
        tag = rel["tag_name"]
        versions.append(
            {
                "version": tag[1:] if tag.startswith("v") else tag,
                "date": rel["published_at"],
                "localizedDescription": (rel.get("body") or "").strip()[:2000],
                "downloadURL": ipa["browser_download_url"],
                "size": ipa["size"],
                "minOSVersion": min_os_version(ipa["browser_download_url"]),
            }
        )
    return versions


def main():
    releases = fetch_releases()
    versions = build_versions(releases)
    if not versions:
        print("没有找到带 .ipa 的正式发布，不生成清单", file=sys.stderr)
        return 1

    source = {
        "name": SOURCE_NAME,
        "identifier": SOURCE_IDENTIFIER,
        "sourceURL": f"https://github.com/{REPO}/releases/latest/download/source.json",
        "website": f"https://github.com/{REPO}",
        "apps": [
            {
                "name": "MangaTranslater",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": DEVELOPER,
                "subtitle": "Comic reader with built-in page translation",
                "localizedDescription": (
                    "A comic reader with built-in page translation. "
                    "Ships with no online sources: import local files (CBZ/ZIP), "
                    "connect your own Komga or Kavita server, or add third-party "
                    "source repository URLs. iOS 18.0 or later."
                ),
                "iconURL": (
                    f"https://raw.githubusercontent.com/{REPO}/main/"
                    "MangaTranslater/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
                ),
                "tintColor": "4A3FA8",
                "category": "entertainment",
                "versions": versions,
            }
        ],
        "news": [],
    }

    with open("source.json", "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"已生成 source.json，含 {len(versions)} 个版本")
    return 0


if __name__ == "__main__":
    sys.exit(main())
