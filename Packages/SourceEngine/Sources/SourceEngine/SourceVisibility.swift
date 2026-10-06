//
//  SourceVisibility.swift
//  SourceEngine
//
//  「哪些源可以出现在界面上」这条规则**只在这里实现一次**。
//
//  为什么单独抽出来：这是合规要求，不是界面细节——
//  声明 `nsfw: true` 的源必须默认隐藏，且只有用户在设置里确认年满 18 岁并
//  显式开启后才可能出现。如果每个界面各自写一遍 `if !source.isNSFW`，
//  早晚会有一个界面漏掉（例如「最近使用」或搜索结果里冒出来）。
//
//  注意：`AppSettings.showsNSFWSources` 自身已经与「年龄确认」绑定
//  （未确认时写入会被拒绝、读取恒为 false），因此这里只认这一个开关，
//  不要再去读 `hasConfirmedAdultContent`，避免两处判断出现分叉。
//

import Foundation

/// 源可见性规则。
public enum SourceVisibilityRule {

    /// 该源当前是否可见。
    public static func isVisible(_ source: InstalledSource, showsNSFWSources: Bool) -> Bool {
        source.isNSFW ? showsNSFWSources : true
    }

    /// 过滤出可见的源（保持传入顺序）。
    public static func visible(
        _ sources: [InstalledSource],
        showsNSFWSources: Bool
    ) -> [InstalledSource] {
        sources.filter { isVisible($0, showsNSFWSources: showsNSFWSources) }
    }

    /// 被隐藏的源（界面据此提示「还有 N 个成人内容源已隐藏」）。
    public static func hidden(
        _ sources: [InstalledSource],
        showsNSFWSources: Bool
    ) -> [InstalledSource] {
        sources.filter { !isVisible($0, showsNSFWSources: showsNSFWSources) }
    }

    /// 被隐藏时的原因文案（交给界面本地化）。
    public static func hiddenReason(_ source: InstalledSource, showsNSFWSources: Bool) -> String? {
        guard !isVisible(source, showsNSFWSources: showsNSFWSources) else { return nil }
        return "该源标记为成人内容，已在设置中隐藏"
    }
}
