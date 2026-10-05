//
//  Localization.swift
//  MangaTranslater
//
//  本地化便捷函数。字符串表位于 Resources/<lang>.lproj/Localizable.strings。
//

import Foundation

/// 取本地化字符串。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
