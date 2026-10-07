//
//  LibraryPreferences.swift
//  MangaTranslater
//
//  书架页的本地偏好。
//
//  排序方式原本放在视图的 `@State` 里，于是**切走再回来、或重启 App 就回到默认**——
//  用户把书架调成「按标题」之后发现它自己变回去了，会以为排序坏了。
//  这里把它固化成「有名字的存储键 + 解析规则」，视图用 `@AppStorage` 读写。
//
//  解析规则刻意是「认不出就回退默认」而不是报错：这个值只有本 App 会写，
//  能读到认不出的内容只说明版本变了或者设置被外部改坏，
//  此时用默认排序继续工作，比抛错或清空用户数据都好。
//

import Foundation
import AppDatabase

enum LibraryPreferences {

    /// 排序偏好的存储键。带 `library.` 前缀，与其它设置项区分开。
    static let sortOrderKey = "library.sortOrder"

    /// 默认排序（与 `LibraryView` 首次进入时的行为一致）。
    static let defaultSortOrder: LibrarySortOrder = .lastRead

    /// 解析存储值；无法识别时回退默认。
    static func sortOrder(from raw: String?) -> LibrarySortOrder {
        guard let raw, let parsed = LibrarySortOrder(rawValue: raw) else {
            return defaultSortOrder
        }
        return parsed
    }
}
