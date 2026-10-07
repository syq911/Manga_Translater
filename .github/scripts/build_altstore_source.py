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

字段依据：AltStore 源的 JSON schema（`apps[].versions[]` 必填
`version` / `date` / `downloadURL` / `size`）。
字段填错的表现是「用户在 AltStore 里加不进源」或「装不上（minOSVersion 不符）」，
这两种都很难自查，因此 `tools/check_altstore_source.py` 会用**合成发布数据**
离线跑一遍这个脚本，把字段与排序问题挡在发版之前。
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
TINT_COLOR = "4A3FA8"
CATEGORY = "entertainment"

SUBTITLE = "Comic reader with built-in page translation"

DESCRIPTION = (
    "A comic reader with built-in page translation. "
    "Ships with no online sources: import local files (CBZ/ZIP), "
    "connect your own Komga or Kavita server, or add third-party "
    "source repository URLs. On-device OCR keeps images on your phone; "
    "only the recognised text is sent for translation. iOS 18.0 or later."
)

# 截图取自仓库（合成的中性界面示意，见 tools/make_screenshots.py）。
# 用 raw 直链而不是 Release 附件：截图不随版本变化，没必要每次发版都传一遍。
SCREENSHOTS = [
    f"https://raw.githubusercontent.com/{REPO}/main/website/assets/screenshots/library.png",
    f"https://raw.githubusercontent.com/{REPO}/main/website/assets/screenshots/reader.png",
    f"https://raw.githubusercontent.com/{REPO}/main/website/assets/screenshots/translation.png",
]

ICON_PATH = "MangaTranslater/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


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


def build_versions(releases, read_min_os=min_os_version):
    """把 Release 列表转成 AltStore 的 versions 数组（按日期从新到旧）。"""
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
                "minOSVersion": read_min_os(ipa["browser_download_url"]),
            }
        )
    # AltStore 期望「新的在前」，并据此判断可升级版本；GitHub API 虽然也返回
    # 新在前，但这里显式排序，免得将来换数据源时悄悄变了顺序。
    versions.sort(key=lambda item: item["date"], reverse=True)
    return versions


def build_source(versions):
    """组装完整的 source.json 结构。"""
    return {
        "name": SOURCE_NAME,
        "identifier": SOURCE_IDENTIFIER,
        "sourceURL": f"https://github.com/{REPO}/releases/latest/download/source.json",
        "website": f"https://github.com/{REPO}",
        "apps": [
            {
                "name": SOURCE_NAME,
                "bundleIdentifier": BUNDLE_ID,
                "developerName": DEVELOPER,
                "subtitle": SUBTITLE,
                "localizedDescription": DESCRIPTION,
                "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/{ICON_PATH}",
                "tintColor": TINT_COLOR,
                "category": CATEGORY,
                "screenshots": SCREENSHOTS,
                "versions": versions,
            }
        ],
        "news": [],
    }


def main():
    releases = fetch_releases()
    versions = build_versions(releases)
    if not versions:
        print("没有找到带 .ipa 的正式发布，不生成清单", file=sys.stderr)
        return 1

    source = build_source(versions)
    with open("source.json", "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"已生成 source.json，含 {len(versions)} 个版本")
    return 0


if __name__ == "__main__":
    sys.exit(main())
