#!/usr/bin/env python3
"""
工程文件完整性检查（本地预检工具）。

覆盖历史上踩过的坑：
1. pbxproj 引用完整性 —— 曾因手写工程文件结构非法，导致 Xcode 的包解析器
   崩溃（`-[PBXResourcesBuildPhase remoteContainerItem]` → exit 134）。
   本脚本校验「所有被引用的对象 ID 都有定义」，并检查关键对象类型齐备。
2. 例外集与磁盘测试文件一致 —— Xcode 16 同步文件夹机制下，测试目录里的
   每个 .swift 必须在两处例外集中登记（App 目标排除 + Tests 目标包含），
   漏登记会导致「测试文件被编进 App」或「测试找不到符号」。
3. 包与工程登记一致 —— Packages/<X> 必须有 Package.swift，且被 pbxproj 引用。
4. 配置文件语法 —— JSON / plist / workflow 关键字。
5. 旧项目名残留 —— 防止复制粘贴时带入其它项目的名字。

用法：python3 tools/check_project.py
"""

import io
import json
import os
import re
import sys

PROJECT = "MangaTranslater.xcodeproj/project.pbxproj"
REQUIRED_ISA = [
    "PBXProject",
    "PBXNativeTarget",
    "PBXFileSystemSynchronizedRootGroup",
    "PBXFileSystemSynchronizedBuildFileExceptionSet",
    "XCLocalSwiftPackageReference",
    "XCSwiftPackageProductDependency",
    "PBXSourcesBuildPhase",
    "PBXFrameworksBuildPhase",
    "PBXResourcesBuildPhase",
    "XCConfigurationList",
    "XCBuildConfiguration",
    "PBXGroup",
]
FORBIDDEN_TOKENS = ["EhViewer", "ehviewer apple"]


def check_pbxproj(errors):
    if not os.path.exists(PROJECT):
        errors.append(f"{PROJECT} 不存在")
        return {}
    text = io.open(PROJECT, encoding="utf-8").read()

    if text.count("{") != text.count("}"):
        errors.append(f"pbxproj 花括号不平衡：{{={text.count('{')}, }}={text.count('}')}")

    defined = set(re.findall(r"^\t\t([0-9A-F]{24})\b", text, re.M))
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    dangling = referenced - defined
    if dangling:
        errors.append(f"pbxproj 引用了未定义的对象：{sorted(dangling)}")

    for isa in REQUIRED_ISA:
        if f"isa = {isa};" not in text:
            errors.append(f"pbxproj 缺少 isa = {isa}")

    for token in FORBIDDEN_TOKENS:
        if token in text:
            errors.append(f"pbxproj 残留旧项目名：{token}")

    return {"text": text, "defined": len(defined)}


def check_exception_sets(errors, info):
    text = info.get("text")
    if not text:
        return

    tests_dir = "MangaTranslater/MangaTranslaterTests"
    disk = set()
    if os.path.isdir(tests_dir):
        disk = {f"MangaTranslaterTests/{n}" for n in os.listdir(tests_dir) if n.endswith(".swift")}

    listed = set(re.findall(r'"(MangaTranslaterTests/[^"]+\.swift)"', text))

    for name in sorted(listed - disk):
        errors.append(f"例外集列出但磁盘不存在：{name}")
    for name in sorted(disk - listed):
        errors.append(f"测试文件未登记进例外集：{name}")

    blocks = re.findall(r"membershipExceptions = \((.*?)\);", text, re.S)
    test_lists = [set(re.findall(r'"(MangaTranslaterTests/[^"]+)"', b)) for b in blocks]
    test_lists = [x for x in test_lists if x]
    if len(test_lists) >= 2 and test_lists[0] != test_lists[1]:
        errors.append("两处例外集的测试文件清单不一致（App 排除集 vs Tests 包含集）")


def check_packages(errors, info):
    text = info.get("text", "")
    if not os.path.isdir("Packages"):
        errors.append("Packages/ 目录不存在")
        return
    for name in sorted(os.listdir("Packages")):
        path = os.path.join("Packages", name)
        if not os.path.isdir(path):
            continue
        manifest = os.path.join(path, "Package.swift")
        if not os.path.exists(manifest):
            errors.append(f"Packages/{name} 缺少 Package.swift")
        else:
            check_package_localization(errors, name, path, manifest)
        if text and f"relativePath = Packages/{name};" not in text:
            errors.append(f"Packages/{name} 未登记进 pbxproj")


def check_package_localization(errors, name, path, manifest):
    """
    包内有 `.lproj` 本地化资源时，`Package.swift` 必须声明 `defaultLocalization`。

    起因（CI 实测）：给 AppCore 加了 `Resources/{en,zh-Hans}.lproj/Localizable.strings`
    并声明 `resources:` 之后，SwiftPM 直接拒绝解析依赖图：

        manifest property 'defaultLocalization' not set;
        it is required in the presence of localized resources

    这个错误发生在 `Resolve Swift packages` 阶段，**编译都没走到**，
    而且报的是 manifest 的问题、指向的是包清单而不是那个 `.lproj` 目录，
    靠读报错很难联想到「我加了本地化资源」。所以在这里提前拦。
    """
    has_lproj = False
    for dirpath, dirnames, _ in os.walk(path):
        if any(d.endswith(".lproj") for d in dirnames):
            has_lproj = True
            break
    if not has_lproj:
        return
    manifest_text = io.open(manifest, encoding="utf-8").read()
    # 用「参数名 + 冒号」而不是包含子串来判断：包含子串会把
    # `defaultLocalizationXXX:` 这种写错的参数名也当成合规（反向验证时踩过）。
    if not re.search(r"\bdefaultLocalization\s*:", manifest_text):
        errors.append(
            f"Packages/{name} 含 .lproj 本地化资源，但 Package.swift 未声明 "
            f"defaultLocalization（SwiftPM 会直接拒绝解析依赖图）"
        )


def check_config_files(errors):
    json_files = [
        "MangaTranslater/Resources/Assets.xcassets/Contents.json",
        "MangaTranslater/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
        "MangaTranslater/Resources/Assets.xcassets/AccentColor.colorset/Contents.json",
    ]
    for path in json_files:
        if not os.path.exists(path):
            errors.append(f"{path} 不存在")
            continue
        try:
            json.load(io.open(path, encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{path} JSON 非法：{exc}")

    for path in ["MangaTranslater/Info.plist", "MangaTranslater/MangaTranslater.entitlements"]:
        if not os.path.exists(path):
            errors.append(f"{path} 不存在")
            continue
        text = io.open(path, encoding="utf-8").read()
        if "<plist" not in text or "</plist>" not in text:
            errors.append(f"{path} 缺少 plist 根元素")

    workflow = ".github/workflows/build-ipa.yml"
    if not os.path.exists(workflow):
        errors.append(f"{workflow} 不存在")
    else:
        text = io.open(workflow, encoding="utf-8").read()
        for key in ["name: Build IPA", "build-ipa:", "test:", "release:",
                    "MangaTranslater.xcodeproj", "MangaTranslater.ipa"]:
            if key not in text:
                errors.append(f"workflow 缺少 {key}")
        for token in FORBIDDEN_TOKENS:
            if token in text:
                errors.append(f"workflow 残留旧项目名：{token}")

    script = ".github/scripts/build_altstore_source.py"
    if not os.path.exists(script):
        errors.append(f"{script} 不存在")
    else:
        text = io.open(script, encoding="utf-8").read()
        for key in ["BUNDLE_ID", "com.mangatranslater.ios", "source.json"]:
            if key not in text:
                errors.append(f"{script} 缺少 {key}")


def main():
    errors = []
    info = check_pbxproj(errors)
    check_exception_sets(errors, info)
    check_packages(errors, info)
    check_config_files(errors)

    print(f"pbxproj 已定义对象：{info.get('defined', 0)} 个")
    if errors:
        print("\n❌ 发现问题：")
        for item in errors:
            print("  -", item)
        return 1
    print("✅ 工程文件检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
