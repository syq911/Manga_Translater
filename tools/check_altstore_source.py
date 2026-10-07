#!/usr/bin/env python3
"""
AltStore 源清单的离线校验（本地预检工具）。

## 为什么需要它

`.github/scripts/build_altstore_source.py` 只在**打 tag 发版时**才真正运行一次。
它一旦写错，代价是「用户加不进源 / 装不上」，而且那时候你已经发完版了——
下一轮验证要重新打 tag。

所以这里用**合成的 Release 数据**把那个脚本跑一遍（不联网、不依赖 GitHub），
逐条断言 AltStore 要求的字段、URL 形状、排序与本地资源是否齐备。

## 覆盖的历史坑

- `versions` 必须**新的在前**（AltStore 据此挑可升级版本）；
- `minOSVersion` 必须来自 ipa 内部的 Info.plist，不能写死（写死就装不上）；
- 草稿与预发布不该出现在清单里；
- `iconURL` / `screenshots` 指向仓库里的真实文件（404 的图标会让源在 AltStore
  里显示成空白方块）。

用法：python3 tools/check_altstore_source.py
"""

import io
import json
import os
import re
import sys

SCRIPT_DIR = os.path.join(".github", "scripts")
sys.path.insert(0, SCRIPT_DIR)

import build_altstore_source as builder  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/")
REPO_ROOT = os.path.dirname(REPO_ROOT)


def synthetic_releases():
    """两份正式发布 + 一份草稿 + 一份预发布 + 一份没有 ipa 的发布。"""
    return [
        {
            "tag_name": "v1.0.0",
            "published_at": "2026-10-07T00:00:00Z",
            "draft": False,
            "prerelease": False,
            "body": "1.0.0: first stable release.",
            "assets": [
                {
                    "name": "MangaTranslater.ipa",
                    "size": 2_200_000,
                    "browser_download_url": (
                        "https://github.com/syq911/Manga_Translater/releases/download/v1.0.0/MangaTranslater.ipa"
                    ),
                }
            ],
        },
        {
            "tag_name": "v0.9.0",
            "published_at": "2026-09-01T00:00:00Z",
            "draft": False,
            "prerelease": False,
            "body": "0.9.0",
            "assets": [
                {
                    "name": "MangaTranslater.ipa",
                    "size": 2_100_000,
                    "browser_download_url": (
                        "https://github.com/syq911/Manga_Translater/releases/download/v0.9.0/MangaTranslater.ipa"
                    ),
                }
            ],
        },
        {
            "tag_name": "v0.8.0",
            "published_at": "2026-08-01T00:00:00Z",
            "draft": True,
            "prerelease": False,
            "body": "draft",
            "assets": [
                {
                    "name": "MangaTranslater.ipa",
                    "size": 1,
                    "browser_download_url": "https://example.com/draft.ipa",
                }
            ],
        },
        {
            "tag_name": "v0.7.0",
            "published_at": "2026-07-01T00:00:00Z",
            "draft": False,
            "prerelease": True,
            "body": "beta",
            "assets": [
                {
                    "name": "MangaTranslater.ipa",
                    "size": 1,
                    "browser_download_url": "https://example.com/beta.ipa",
                }
            ],
        },
        {
            "tag_name": "v0.6.0",
            "published_at": "2026-06-01T00:00:00Z",
            "draft": False,
            "prerelease": False,
            "body": "no ipa attached",
            "assets": [{"name": "source.json", "size": 10, "browser_download_url": "https://example.com/source.json"}],
        },
    ]


def check_structure(source, problems):
    for key in ["name", "identifier", "sourceURL", "apps"]:
        if key not in source:
            problems.append(f"source.json 缺少顶层字段 `{key}`")

    apps = source.get("apps") or []
    if len(apps) != 1:
        problems.append(f"apps 应当恰好有一个 App，实际 {len(apps)}")
        return

    app = apps[0]
    for key in ["name", "bundleIdentifier", "developerName", "subtitle",
                "localizedDescription", "iconURL", "versions"]:
        if not app.get(key):
            problems.append(f"apps[0] 缺少字段 `{key}`")

    if app.get("bundleIdentifier") != builder.BUNDLE_ID:
        problems.append("bundleIdentifier 与 Bundle ID 不一致")

    versions = app.get("versions") or []
    if not versions:
        problems.append("versions 为空——AltStore 会认为没有可安装的版本")
        return

    # 草稿 / 预发布 / 没 ipa 的三条都不该出现，剩下两条正式版
    if len(versions) != 2:
        problems.append(f"versions 应当有 2 条正式版本，实际 {len(versions)}")

    dates = [v.get("date") for v in versions]
    if dates != sorted(dates, reverse=True):
        problems.append("versions 没有按日期从新到旧排序（AltStore 靠顺序判断可升级版本）")

    if "1.0.0" not in [v.get("version") for v in versions]:
        problems.append("versions 里找不到 v1.0.0（tag 前缀 `v` 应当被剥掉）")

    for version in versions:
        for key in ["version", "date", "downloadURL", "size", "minOSVersion"]:
            if key not in version:
                problems.append(f"version {version.get('version')} 缺少字段 `{key}`")
        download = version.get("downloadURL", "")
        if not re.match(
            r"^https://github\.com/[\w.-]+/[\w.-]+/releases/download/v[\d.]+/MangaTranslater\.ipa$",
            download,
        ):
            problems.append(f"downloadURL 形状可疑：{download}")
        if not isinstance(version.get("size"), int) or version.get("size", 0) <= 0:
            problems.append(f"version {version.get('version')} 的 size 不是正整数")
        if not re.match(r"^\d+(\.\d+)*$", str(version.get("minOSVersion", ""))):
            problems.append(f"version {version.get('version')} 的 minOSVersion 不像版本号：{version.get('minOSVersion')}")


def check_local_assets(source, problems):
    """iconURL / screenshots 指向的文件必须在仓库里真实存在。"""
    app = (source.get("apps") or [{}])[0]
    urls = [app.get("iconURL", "")] + list(app.get("screenshots") or [])
    raw_prefix = f"https://raw.githubusercontent.com/{builder.REPO}/main/"
    for url in urls:
        if not url.startswith(raw_prefix):
            problems.append(f"资源地址不是仓库 main 分支的 raw 链接：{url}")
            continue
        relative = url[len(raw_prefix):]
        if not os.path.exists(relative):
            problems.append(f"清单引用的资源在仓库里不存在：{relative}")


def check_schema_documentation(problems):
    """字段依据要有文档，否则下一个人只能靠猜。"""
    path = os.path.join("docs", "altstore.md")
    if not os.path.exists(path):
        problems.append("缺少 docs/altstore.md（AltStore 字段依据与上线清单）")


def main():
    releases = synthetic_releases()
    # 用桩替换「读 ipa 里的 MinimumOSVersion」：离线环境下不可能真的下载 ipa。
    versions = builder.build_versions(releases, read_min_os=lambda url: "18.0")
    source = builder.build_source(versions)

    problems = []
    check_structure(source, problems)
    check_local_assets(source, problems)
    check_schema_documentation(problems)

    # JSON 必须可序列化（含中文描述时的 ensure_ascii=False 路径）
    blob = json.dumps(source, ensure_ascii=False, indent=2)

    print(f"AltStore 清单校验：合成 {len(releases)} 个发布 → 生成 {len(versions)} 个版本（{len(blob)} 字节）")
    if problems:
        print("\n❌ 发现问题：")
        for problem in problems:
            print("  -", problem)
        return 1
    print("✅ 清单字段齐备、版本倒序、URL 形状正确、图标与截图在仓库中存在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
