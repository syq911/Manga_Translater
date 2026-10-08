//
//  LibraryUpdateRule.swift
//  AppCore
//
//  书架的「检查更新」：拿一次章节列表，判断这部作品有没有新章节。
//
//  为什么值得单独写一个判定（而不是在视图里 `chapters.count > ...`）：
//
//  1. **数据的顺序不可信。** 不同源返回的章节列表可能新→旧、也可能旧→新，
//     还有的只给名字不给章节号。用一个「数量变多就算有更新」的土办法，
//     源换一次排序就会把整架作品标成「有新章节」——用户从此不信这个角标。
//  2. **不能猜。** 判断不出来的时候正确答案是「不知道」，而不是「猜一个」。
//     角标是用户用来决定「要不要点进去」的信号，谎报比不报更糟。
//
//  于是判定只有三种结果，且「不知道」是一等公民：
//
//  | 结果 | 依据 |
//  |---|---|
//  | `.upToDate` | 有可比较的信号，且没有更新的章节号 |
//  | `.newChapters(n)` | 有可比较的信号，n 个章节号大于上次读到的那个 |
//  | `.unknown` | 没读过 / 上次读的章节已不在列表里 / 两边都没有章节号 |
//

import Foundation

/// 「有没有新章节」的判定结果。
public enum LibraryUpdateVerdict: Equatable, Sendable {
    case upToDate
    case newChapters(count: Int)
    /// 信号不足，不下判断。
    case unknown

    /// 判定结果里的新章节数（`unknown` 与 `upToDate` 都是 0）。
    public var newChapterCount: Int {
        if case let .newChapters(count) = self { return count }
        return 0
    }
}

public enum LibraryUpdateRule {

    /// 判断某部作品是否有新章节。
    ///
    /// - Parameters:
    ///   - chapters: 刚从来源拉到的章节列表（顺序任意）。
    ///   - lastReadChapterID: 书架里记的「上次读到的章节」。
    public static func verdict(chapters: [Chapter], lastReadChapterID: String?) -> LibraryUpdateVerdict {
        guard let lastReadChapterID else {
            // 从没读过：谈不上「新章节」（未读是另一件事，界面用进度文案表达）
            return .unknown
        }
        guard let baseline = chapters.first(where: { $0.id == lastReadChapterID }) else {
            // 上次读的那一章不在列表里了：源改过标识或删过章节，此时**任何**比较都不可靠
            return .unknown
        }
        guard let baselineNumber = baseline.chapterNumber else {
            // 没有章节号就没有可靠的「谁更新」——列表顺序不可信，不猜
            return .unknown
        }
        let newer = chapters.filter { chapter in
            guard let number = chapter.chapterNumber else { return false }
            return number > baselineNumber
        }
        return newer.isEmpty ? .upToDate : .newChapters(count: newer.count)
    }

    /// 批量判定的一句话汇总（界面用它拼提示文案）。
    public struct Summary: Equatable, Sendable {
        /// 有新章节的作品数。
        public let mangasWithNewChapters: Int
        /// 新章节总数。
        public let newChapterTotal: Int
        /// 确认已是最新的作品数。
        public let upToDate: Int
        /// 判断不出来的作品数。
        public let unknown: Int

        public init(mangasWithNewChapters: Int, newChapterTotal: Int, upToDate: Int, unknown: Int) {
            self.mangasWithNewChapters = mangasWithNewChapters
            self.newChapterTotal = newChapterTotal
            self.upToDate = upToDate
            self.unknown = unknown
        }
    }

    public static func summary(_ verdicts: [LibraryUpdateVerdict]) -> Summary {
        var withNew = 0
        var total = 0
        var upToDate = 0
        var unknown = 0
        for verdict in verdicts {
            switch verdict {
            case .upToDate:
                upToDate += 1
            case let .newChapters(count):
                withNew += 1
                total += count
            case .unknown:
                unknown += 1
            }
        }
        return Summary(
            mangasWithNewChapters: withNew,
            newChapterTotal: total,
            upToDate: upToDate,
            unknown: unknown
        )
    }
}
