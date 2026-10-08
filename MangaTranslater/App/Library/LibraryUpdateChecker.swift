//
//  LibraryUpdateChecker.swift
//  MangaTranslater
//
//  书架的「下拉检查更新」（手册 §5.3：逐源拉章节列表比对）。
//
//  职责刻意收得很窄：**只拉章节列表、只算「有没有新章节」**，
//  然后把结果写回书架的未读角标。
//
//  两件它**不做**的事，都是刻意的：
//
//  - 不刷新标题 / 封面。那是「打开作品详情」的活；为一次检查把每部作品的详情
//    都拉一遍，请求量翻倍，而用户看得见的差别只有封面。
//  - 不猜。判断不出来的时候（源没给章节号、上次读的那话不见了）它**什么都不写**，
//    而不是把角标清零或拍一个数字——角标是用户决定「要不要点进去」的信号，
//    谎报比不报更糟。
//
//  依赖用闭包注入、类型是 `Sendable`，因此：测试可以完全不碰网络与 JS 沙箱；
//  并发抓取也不需要把请求和响应在 actor 之间搬来搬去（章节列表本身是纯值）。
//

import Foundation
import AppCore
import AppDatabase

/// 一次检查的汇总结果（界面据此拼一句提示）。
struct LibraryUpdateOutcome: Equatable, Sendable {
    /// 实际检查了几部作品（跳过本地文件）。
    var checked: Int = 0
    /// 有新章节的作品数。
    var withNewChapters: Int = 0
    /// 新章节总数。
    var newChapterTotal: Int = 0
    /// 判断不出来的作品数。
    var unknown: Int = 0
    /// 拉章节列表失败的作品数。
    var failed: Int = 0

    /// 有没有值得报告的「新东西」。
    var foundSomething: Bool { withNewChapters > 0 }
}

struct LibraryUpdateChecker: Sendable {

    /// 拉某部作品的章节列表。注入而不是直接依赖数据来源，测试才好写。
    typealias ChapterLoader = @Sendable (Manga) async throws -> [Chapter]

    let loadChapters: ChapterLoader
    let libraryStore: LibraryStoring
    /// 并发上限：这是网络请求，不能一口气把整架作品全发出去，
    /// 但串行又太慢（书架常见几十部）。3 与手册 §5.5 的「单源并发 ≤3」一致。
    var maxConcurrent = 3

    /// 子任务的结果。
    ///
    /// 刻意不用 `Result<[Chapter], Error>`：`Error` 不是 `Sendable`，
    /// 把错误对象跨任务传是一次没必要的跨越——我们只需要知道「失败了」。
    private enum LoadOutcome: Sendable {
        case chapters(mangaID: String, [Chapter])
        case failed(mangaID: String)
    }

    /// 检查一批作品，并把未读角标写回书架。
    func check(_ entries: [LibraryEntry]) async -> LibraryUpdateOutcome {
        // 本地文件没有「来源」可查（文件就是全部内容），跳过
        let online = entries.filter { $0.manga.sourceID != .local }
        var outcome = LibraryUpdateOutcome()
        guard !online.isEmpty else { return outcome }

        // 每部作品「上次读到哪一章」先做成表：子任务只回传章节列表，
        // 比对在主流程里做，避免把整个条目（含封面 URL 等）跨任务搬。
        let baselines = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.manga.id, $0.lastReadChapterID) }
        )

        let batch = max(1, maxConcurrent)
        var index = 0
        while index < online.count {
            let slice = Array(online[index..<min(index + batch, online.count)])
            index += batch

            await withTaskGroup(of: LoadOutcome.self) { group in
                for entry in slice {
                    let manga = entry.manga
                    let load = loadChapters
                    group.addTask {
                        do {
                            return .chapters(mangaID: manga.id, try await load(manga))
                        } catch {
                            return .failed(mangaID: manga.id)
                        }
                    }
                }

                for await result in group {
                    outcome.checked += 1
                    switch result {
                    case let .chapters(mangaID, chapters):
                        let verdict = LibraryUpdateRule.verdict(
                            chapters: chapters,
                            lastReadChapterID: baselines[mangaID] ?? nil
                        )
                        switch verdict {
                        case .upToDate:
                            applyUnreadCount(0, mangaID: mangaID)
                        case let .newChapters(count):
                            outcome.withNewChapters += 1
                            outcome.newChapterTotal += count
                            applyUnreadCount(count, mangaID: mangaID)
                        case .unknown:
                            // 判断不出来就**保持原样**：既不清零也不改数字
                            outcome.unknown += 1
                        }
                    case let .failed(mangaID):
                        // 失败也不动角标：这次没拉到，不代表没有新章节
                        _ = mangaID
                        outcome.failed += 1
                    }
                }
            }
        }
        return outcome
    }

    private func applyUnreadCount(_ count: Int, mangaID: String) {
        // 写角标失败不该让整次检查失败：角标只是提示，下次刷新还会再写一遍。
        _ = try? libraryStore.setUnreadCount(mangaID: mangaID, count: count)
    }
}
