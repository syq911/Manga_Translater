//
//  Localization+Names.swift
//  MangaTranslater
//
//  包层枚举的**展示名**。
//
//  背景：`ReaderMode` / `ReaderTheme` / `TranslationBackend` / `TranslationLanguage`
//  （AppCore）、`LibrarySortOrder`（AppDatabase）、`ChallengeKind`（SourceEngine）
//  都是纯模型类型，它们原先各自带一个中文 `displayName`。
//  那些 `displayName` 一旦被 Picker 直接渲染，英文界面里就会出现中文选项——
//  而这是编译器与本地检查器都看不见的一类缺陷（M5 中英双语文案复核的重点）。
//
//  现在把展示名统一收在 App 层：
//  - 模型层只留语言无关的 case，不再持有任何文案；
//  - 这里用 `L("…")` 字面量，于是 `tools/check_localization.py` 能验证
//    「用到的 key 都已定义、两种语言的占位符一致」；
//  - `tools/check_hardcoded_copy.py` 保证包层不会重新长出硬编码文案。
//

import Foundation
import AppCore
import AppDatabase
import SourceEngine

// MARK: - 翻译

extension TranslationBackend {
    var localizedName: String {
        switch self {
        case .bringYourOwnKey: return L("translation.backend.bringYourOwnKey")
        case .cloudService: return L("translation.backend.cloudService")
        case .appleOnDevice: return L("translation.backend.appleOnDevice")
        }
    }
}

extension TranslationLanguage {
    var localizedName: String {
        switch self {
        case .auto: return L("translation.language.auto")
        case .japanese: return L("translation.language.japanese")
        case .english: return L("translation.language.english")
        case .simplifiedChinese: return L("translation.language.simplifiedChinese")
        case .traditionalChinese: return L("translation.language.traditionalChinese")
        case .korean: return L("translation.language.korean")
        }
    }
}

// MARK: - 阅读器

extension ReaderMode {
    var localizedName: String {
        switch self {
        case .pagedLeftToRight: return L("reader.mode.pagedLeftToRight")
        case .pagedRightToLeft: return L("reader.mode.pagedRightToLeft")
        case .continuousVertical: return L("reader.mode.continuousVertical")
        case .doublePage: return L("reader.mode.doublePage")
        }
    }
}

extension ReaderTheme {
    var localizedName: String {
        switch self {
        case .system: return L("reader.theme.system")
        case .light: return L("reader.theme.light")
        case .sepia: return L("reader.theme.sepia")
        case .dark: return L("reader.theme.dark")
        case .black: return L("reader.theme.black")
        }
    }
}

// MARK: - 书架

extension LibrarySortOrder {
    var localizedName: String {
        switch self {
        case .lastRead: return L("library.sort.byLastRead")
        case .title: return L("library.sort.byTitle")
        case .recentlyAdded: return L("library.sort.byRecentlyAdded")
        }
    }
}

// MARK: - 来源

extension ChallengeKind {
    /// 「人工验证」提示里说明是哪一种校验，比笼统一句「可能要求验证」有用。
    var localizedName: String {
        switch self {
        case .cloudflare: return L("verify.kind.cloudflare")
        case .captcha: return L("verify.kind.captcha")
        case .generic: return L("verify.kind.generic")
        }
    }
}
