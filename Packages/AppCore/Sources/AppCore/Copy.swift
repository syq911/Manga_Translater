//
//  Copy.swift
//  AppCore
//
//  包层文案表。
//
//  为什么需要这一层：`AppCore` / `ComicNet` / `SourceEngine` / `ComicDownload` /
//  `AppDatabase` 是纯 Foundation 包，**拿不到 App 目标的 `L()`**（依赖方向不允许
//  反向引用）。于是这些包里的错误文案长期只能是硬编码中文——
//  而它们是用户可见的：源加载失败、归档损坏、下载失败的原因都会原样显示在界面上。
//  结果就是「英文界面里冒出中文句子」，这正是 M5 中英双语文案复核要根治的问题。
//
//  解决办法是把文案表下沉进包：`Resources/{en,zh-Hans}.lproj/Localizable.strings`
//  随 SwiftPM 资源包（`Bundle.module`）打进 App，包内统一走这里的 `text` / `format`。
//  这样：
//
//  1. 包内不再出现任何硬编码文案（`tools/check_hardcoded_copy.py` 会拦）；
//  2. 语言由系统按 App 的当前语言解析，与 App 目标自己的字符串表互不干扰；
//  3. key 清单由 `tools/check_localization.py` 双向校验
//     （代码用到的 key 必须存在；两种语言的 key 集合必须一致）。
//
//  key 命名约定：`<域>.<类型>.<情形>`，例如 `error.net.timeout`。
//  包层 key 与 App 目标 key 刻意不共用前缀以外的命名空间，避免「取错表」。
//
//  容错：查不到 key 时**返回 key 本身**（而不是空串或英文兜底）。
//  把 `error.net.timeout` 显示出来很丑，但它是可诊断的；
//  静默显示一个看似正常的句子才是真正难查的那类问题。
//

import Foundation

public enum Copy {

    /// 取一条本地化文案。
    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 取一条带占位符的本地化文案（占位符按 `String(format:)` 规则）。
    ///
    /// 例：`Copy.format("error.net.timeout", seconds)`。
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    /// 当前解析到的那张表（测试用：确认资源包真的被装进来了）。
    public static var resolvedLanguage: String {
        bundle.preferredLocalizations.first ?? bundle.developmentLocalization ?? "en"
    }

    /// 资源包本体。
    ///
    /// `Bundle.module` 由 SwiftPM 生成；如果 `Package.swift` 里漏了
    /// `resources:` 声明，编译器会直接报错而不是运行期悄悄失败——这是刻意选的：
    /// 让「文案表没打进 App」变成编译错误，而不是上线后才发现界面上全是 key。
    private static var bundle: Bundle { .module }
}
