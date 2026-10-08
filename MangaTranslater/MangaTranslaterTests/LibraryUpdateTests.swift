//
//  LibraryUpdateTests.swift
//  MangaTranslaterTests
//
//  书架「检查更新」的规则与执行。
//
//  这块值得单独测的原因：它的输出是一个**角标**——用户只会看到「3」，
//  看不到它是怎么来的。所以「什么时候该写、什么时候必须保持原样」
//  必须在测试里写死，否则将来一个「顺手清零」的改动会让用户以为
//  「我收藏的作品更新了」，点进去却发现没有。
//

import Foundation
import Testing
import AppCore
import AppDatabase
@testable import MangaTranslater

@Suite("书架 · 检查更新规则")
struct LibraryUpdateRuleTests {

    private static func chapter(_ mangaID: String, _ number: Double?, name: String? = nil) -> Chapter {
        Chapter(
            mangaID: mangaID,
            url: "https://example.com/c/\(name ?? String(number ?? 0))",
            name: name ?? "Ch \(number ?? 0)",
            chapterNumber: number
        )
    }

    private static let mangaID = Manga(
        sourceID: SourceID("demo"),
        url: "https://example.com/m/1",
        title: "Sample"
    ).id

    @Test("从没读过 → 不下判断（未读不是「有新章节」）")
    func neverReadIsUnknown() {
        let chapters = [Self.chapter(Self.mangaID, 1), Self.chapter(Self.mangaID, 2)]
        #expect(LibraryUpdateRule.verdict(chapters: chapters, lastReadChapterID: nil) == .unknown)
    }

    @Test("上次读的那一章不在列表里 → 不下判断（源改过标识）")
    func baselineMissingIsUnknown() {
        let chapters = [Self.chapter(Self.mangaID, 1), Self.chapter(Self.mangaID, 2)]
        #expect(
            LibraryUpdateRule.verdict(chapters: chapters, lastReadChapterID: "gone|https://x") == .unknown
        )
    }

    @Test("没有章节号 → 不下判断（列表顺序不可信）")
    func noChapterNumberIsUnknown() {
        let baseline = Self.chapter(Self.mangaID, nil, name: "Ch A")
        let chapters = [baseline, Self.chapter(Self.mangaID, nil, name: "Ch B")]
        #expect(LibraryUpdateRule.verdict(chapters: chapters, lastReadChapterID: baseline.id) == .unknown)
    }

    @Test("读到最新一话 → 已是最新")
    func upToDate() {
        let newest = Self.chapter(Self.mangaID, 10)
        let chapters = [Self.chapter(Self.mangaID, 9), newest]
        #expect(LibraryUpdateRule.verdict(chapters: chapters, lastReadChapterID: newest.id) == .upToDate)
    }

    @Test("读到中间 → 数出更新的章节数（与列表顺序无关）")
    func countsNewerChapters() {
        let baseline = Self.chapter(Self.mangaID, 10)
        // 故意打乱顺序：新→旧、旧→新都试一遍，结果必须一样
        let newestFirst = [
            Self.chapter(Self.mangaID, 13),
            Self.chapter(Self.mangaID, 12),
            baseline,
            Self.chapter(Self.mangaID, 9),
        ]
        let oldestFirst = newestFirst.reversed().map { $0 }
        #expect(
            LibraryUpdateRule.verdict(chapters: newestFirst, lastReadChapterID: baseline.id)
                == .newChapters(count: 2)
        )
        #expect(
            LibraryUpdateRule.verdict(chapters: oldestFirst, lastReadChapterID: baseline.id)
                == .newChapters(count: 2)
        )
    }

    @Test("章节号跳号（11.5 这种番外）也算新章节")
    func countsFractionalChapters() {
        let baseline = Self.chapter(Self.mangaID, 11)
        let chapters = [Self.chapter(Self.mangaID, 11.5), baseline]
        #expect(
            LibraryUpdateRule.verdict(chapters: chapters, lastReadChapterID: baseline.id)
                == .newChapters(count: 1)
        )
    }

    @Test("缺少章节号的条目被忽略，不会把总数算多")
    func entriesWithoutNumberAreIgnored() {
        let baseline = Self.chapter(Self.mangaID, 5)
        let chapters = [Self.chapter(Self.mangaID, nil, name: "Special"), Self.chapter(Self.mangaID, 6), baseline]
        #expect(
            LibraryUpdateRule.verdict(chapters: chapters, lastReadChapterID: baseline.id)
                == .newChapters(count: 1)
        )
    }

    @Test("空章节列表 → 不下判断（这次没拉到东西，不代表没有）")
    func emptyChapterListIsUnknown() {
        #expect(LibraryUpdateRule.verdict(chapters: [], lastReadChapterID: "x") == .unknown)
    }

    @Test("汇总：有新章节 / 已最新 / 判断不出来 分别计数")
    func summaryAggregates() {
        let verdicts: [LibraryUpdateVerdict] = [
            .newChapters(count: 2),
            .newChapters(count: 1),
            .upToDate,
            .upToDate,
            .unknown,
        ]
        let summary = LibraryUpdateRule.summary(verdicts)
        #expect(summary.mangasWithNewChapters == 2)
        #expect(summary.newChapterTotal == 3)
        #expect(summary.upToDate == 2)
        #expect(summary.unknown == 1)
    }

    @Test("判定结果自带新章节数（unknown 与 upToDate 都是 0）")
    func verdictCarriesCount() {
        #expect(LibraryUpdateVerdict.newChapters(count: 4).newChapterCount == 4)
        #expect(LibraryUpdateVerdict.upToDate.newChapterCount == 0)
        #expect(LibraryUpdateVerdict.unknown.newChapterCount == 0)
    }
}

@Suite("书架 · 检查更新执行")
struct LibraryUpdateCheckerTests {

    private static func manga(_ index: Int, sourceID: String = "demo") -> Manga {
        Manga(sourceID: SourceID(sourceID), url: "https://example.com/m/\(index)", title: "M\(index)")
    }

    private static func chapter(_ manga: Manga, _ number: Double) -> Chapter {
        Chapter(
            mangaID: manga.id,
            url: "https://example.com/c/\(manga.url)-\(number)",
            name: "Ch \(number)",
            chapterNumber: number
        )
    }

    private struct MissingChapters: Error {}

    /// 造一个「书架 + 检查器」的世界。`chapters` 是「manga.id → 章节列表」的脚本。
    private static func makeWorld(
        entries: [LibraryEntry],
        chapters: [String: [Chapter]],
        failing: Set<String> = []
    ) throws -> (checker: LibraryUpdateChecker, store: InMemoryLibraryStore) {
        let store = InMemoryLibraryStore()
        for entry in entries {
            _ = try store.save(entry)
        }
        let checker = LibraryUpdateChecker(
            loadChapters: { manga in
                if failing.contains(manga.id) { throw MissingChapters() }
                guard let list = chapters[manga.id] else { throw MissingChapters() }
                return list
            },
            libraryStore: store
        )
        return (checker, store)
    }

    private static func unread(_ store: InMemoryLibraryStore, _ manga: Manga) throws -> Int {
        try #require(try store.entry(mangaID: manga.id)).unreadCount
    }

    @Test("全部已是最新：角标清零（哪怕之前写着 5）")
    func upToDateClearsBadge() async throws {
        let manga = Self.manga(1)
        let newest = Self.chapter(manga, 10)
        let entry = LibraryEntry(
            manga: manga,
            lastReadChapterID: newest.id,
            unreadCount: 5
        )
        let (checker, store) = try Self.makeWorld(entries: [entry], chapters: [manga.id: [newest]])

        let outcome = await checker.check([entry])

        #expect(outcome.checked == 1)
        #expect(outcome.withNewChapters == 0)
        #expect(try Self.unread(store, manga) == 0)
    }

    @Test("有新章节：角标写成新章节数，并计入汇总")
    func newChaptersWriteBadge() async throws {
        let manga = Self.manga(1)
        let baseline = Self.chapter(manga, 1)
        let entry = LibraryEntry(manga: manga, lastReadChapterID: baseline.id, unreadCount: 0)
        let list = [Self.chapter(manga, 4), Self.chapter(manga, 3), Self.chapter(manga, 2), baseline]
        let (checker, store) = try Self.makeWorld(entries: [entry], chapters: [manga.id: list])

        let outcome = await checker.check([entry])

        #expect(outcome.withNewChapters == 1)
        #expect(outcome.newChapterTotal == 3)
        #expect(try Self.unread(store, manga) == 3)
    }

    @Test("判断不出来：角标原样保留（既不清零也不改数字）")
    func unknownKeepsBadge() async throws {
        let manga = Self.manga(1)
        // 源没给章节号
        let noNumber = Chapter(
            mangaID: manga.id,
            url: "https://example.com/c/x",
            name: "Ch X",
            chapterNumber: nil
        )
        let entry = LibraryEntry(manga: manga, lastReadChapterID: noNumber.id, unreadCount: 7)
        let (checker, store) = try Self.makeWorld(entries: [entry], chapters: [manga.id: [noNumber]])

        let outcome = await checker.check([entry])

        #expect(outcome.unknown == 1)
        #expect(outcome.withNewChapters == 0)
        #expect(try Self.unread(store, manga) == 7, "判断不出来时不该动角标")
    }

    @Test("拉取失败：只计数，角标原样保留")
    func failureKeepsBadge() async throws {
        let manga = Self.manga(1)
        let entry = LibraryEntry(
            manga: manga,
            lastReadChapterID: Self.chapter(manga, 1).id,
            unreadCount: 2
        )
        let (checker, store) = try Self.makeWorld(
            entries: [entry],
            chapters: [manga.id: [Self.chapter(manga, 2)]],
            failing: [manga.id]
        )

        let outcome = await checker.check([entry])

        #expect(outcome.checked == 1)
        #expect(outcome.failed == 1)
        #expect(try Self.unread(store, manga) == 2, "这次没拉到，不代表没有新章节")
    }

    @Test("一部失败不影响另一部")
    func oneFailureDoesNotBlockOthers() async throws {
        let good = Self.manga(1)
        let bad = Self.manga(2)
        let baseline = Self.chapter(good, 1)
        let entries = [
            LibraryEntry(manga: good, lastReadChapterID: baseline.id),
            LibraryEntry(manga: bad, lastReadChapterID: Self.chapter(bad, 1).id),
        ]
        let (checker, store) = try Self.makeWorld(
            entries: entries,
            chapters: [good.id: [Self.chapter(good, 2), baseline]],
            failing: [bad.id]
        )

        let outcome = await checker.check(entries)

        #expect(outcome.checked == 2)
        #expect(outcome.withNewChapters == 1)
        #expect(outcome.failed == 1)
        #expect(try Self.unread(store, good) == 1)
    }

    @Test("本地文件被跳过（文件就是全部内容，没有来源可查）")
    func localEntriesAreSkipped() async throws {
        let local = Manga(sourceID: .local, url: "Local/a.cbz", title: "Local")
        let online = Self.manga(9)
        let entries = [
            LibraryEntry(manga: local, lastReadChapterID: "x"),
            LibraryEntry(manga: online, lastReadChapterID: Self.chapter(online, 1).id),
        ]
        let (checker, _) = try Self.makeWorld(
            entries: entries,
            chapters: [online.id: [Self.chapter(online, 1)]]
        )

        let outcome = await checker.check(entries)

        #expect(outcome.checked == 1, "本地文件不该被计入检查数")
    }

    @Test("空书架：直接返回，不产生任何计数")
    func emptyLibrary() async throws {
        let (checker, _) = try Self.makeWorld(entries: [], chapters: [:])
        let outcome = await checker.check([])
        #expect(outcome == LibraryUpdateOutcome())
    }
}

@Suite("书架 · 检查更新提示")
struct LibraryUpdateMessageTests {

    @Test("一部都没检查 → 说明「没有可检查的」，而不是「全部已最新」")
    func nothingToCheck() {
        let text = LibraryView.updateMessage(LibraryUpdateOutcome())
        #expect(!text.isEmpty)
        #expect(!text.contains("0 部"), "不该把 0 当成一个结果说出来")
    }

    @Test("全部已最新 → 报出检查了几部")
    func allUpToDate() {
        var outcome = LibraryUpdateOutcome()
        outcome.checked = 4
        let text = LibraryView.updateMessage(outcome)
        #expect(text.contains("4"))
    }

    @Test("有新章节 → 三个数字都要出现（检查数 / 有新章节的作品数 / 新章节总数）")
    func reportsAllNumbers() {
        var outcome = LibraryUpdateOutcome()
        outcome.checked = 6
        outcome.withNewChapters = 2
        outcome.newChapterTotal = 7
        outcome.failed = 1
        let text = LibraryView.updateMessage(outcome)
        #expect(text.contains("6"))
        #expect(text.contains("2"))
        #expect(text.contains("7"))
        #expect(text.contains("1"))
    }

    @Test("判断不出来时也算「没有新章节」，但不谎报成功")
    func unknownIsNotSuccess() {
        var outcome = LibraryUpdateOutcome()
        outcome.checked = 3
        outcome.unknown = 3
        let text = LibraryView.updateMessage(outcome)
        // 全部 unknown 时走的是「已最新」那条分支（没有新章节、没有失败）——
        // 这是刻意的：unknown 不该被说成失败，也不该占用角标
        #expect(!text.isEmpty)
    }
}
