//
//  LibraryStoreTests.swift
//  MangaTranslaterTests
//
//  书架持久层（GRDB）测试：CRUD、排序、分类、进度、历史、并发、持久化、
//  损坏数据与事务一致性。
//
//  全部使用内存数据库；只有一个用例落磁盘（验证重启后数据仍在）并自行清理。
//

import Testing
import Foundation
import AppCore
@testable import AppDatabase

@Suite("书架持久层")
struct LibraryStoreTests {

    // MARK: 夹具

    private func makeStore() throws -> (DatabaseLibraryStore, AppDatabase) {
        let database = try AppDatabase.open(.memory)
        return (DatabaseLibraryStore(database: database), database)
    }

    private func makeManga(
        id: String,
        source: SourceID = SourceID("demo"),
        title: String? = nil,
        author: String? = "作者",
        genres: [String] = ["a", "b"]
    ) -> Manga {
        Manga(
            sourceID: source,
            url: "https://example.com/\(id)",
            title: title ?? "作品 \(id)",
            author: author,
            artist: "画师",
            summary: "简介",
            genres: genres,
            status: .ongoing,
            coverURL: "https://example.com/\(id).jpg"
        )
    }

    private func makeEntry(
        id: String,
        title: String? = nil,
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        categoryID: String? = nil,
        isPinned: Bool = false,
        lastReadAt: Date? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            manga: makeManga(id: id, title: title),
            addedAt: addedAt,
            categoryID: categoryID,
            lastReadAt: lastReadAt,
            isPinned: isPinned
        )
    }

    // MARK: 打开与迁移

    @Test("打开内存库后迁移已应用")
    func migratesOnOpen() throws {
        let (_, database) = try makeStore()
        #expect(try database.appliedMigrations() == Migrations.all)
        #expect(try database.currentSchemaVersion() == Migrations.all.last)
    }

    @Test("空库查询返回空结果")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        #expect(try store.count() == 0)
        #expect(try store.entries(sortedBy: .lastRead, categoryID: nil).isEmpty)
        #expect(try store.entry(mangaID: "nope") == nil)
        #expect(try store.contains(mangaID: "nope") == false)
        #expect(try store.categories().isEmpty)
        #expect(try store.recentHistory(limit: 10).isEmpty)
    }

    // MARK: 保存与读取

    @Test("保存后可完整读回")
    func savesAndReadsBack() throws {
        let (store, _) = try makeStore()
        let manga = makeManga(id: "one", title: "作品一", genres: ["热血", "冒险"])
        let entry = LibraryEntry(manga: manga, addedAt: Date(timeIntervalSince1970: 100), categoryID: "收藏")

        try store.save(entry)
        let loaded = try #require(try store.entry(mangaID: manga.id))

        #expect(loaded == entry)
        #expect(loaded.manga.genres == ["热血", "冒险"])
        #expect(loaded.manga.author == "作者")
        #expect(loaded.categoryID == "收藏")
        #expect(try store.count() == 1)
        #expect(try store.contains(mangaID: manga.id))
    }

    @Test("重复保存是 upsert，不产生重复行")
    func saveIsUpsert() throws {
        let (store, _) = try makeStore()
        var entry = makeEntry(id: "one")
        try store.save(entry)

        entry.manga.title = "改过的标题"
        entry.categoryID = "新分类"
        try store.save(entry)

        #expect(try store.count() == 1)
        let loaded = try #require(try store.entry(mangaID: entry.id))
        #expect(loaded.manga.title == "改过的标题")
        #expect(loaded.categoryID == "新分类")
    }

    @Test("Unicode 标题可往返")
    func unicodeTitleRoundTrip() throws {
        let (store, _) = try makeStore()
        let title = "【中文】タイトル 한글 emoji 🎌"
        let entry = makeEntry(id: "uni", title: title)
        try store.save(entry)
        #expect(try store.entry(mangaID: entry.id)?.manga.title == title)
    }

    // MARK: 排序与筛选

    @Test("按最近阅读排序：置顶优先，未读在最后")
    func sortsByLastRead() throws {
        let (store, _) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000)
        try store.save(makeEntry(id: "unread", addedAt: t0))
        try store.save(makeEntry(id: "old", addedAt: t0, lastReadAt: t0.addingTimeInterval(10)))
        try store.save(makeEntry(id: "recent", addedAt: t0, lastReadAt: t0.addingTimeInterval(20)))
        try store.save(makeEntry(id: "pinned", addedAt: t0, isPinned: true))

        let ids = try store.entries(sortedBy: .lastRead, categoryID: nil).map(\.id)
        #expect(ids.first?.contains("pinned") == true)
        #expect(ids[1].contains("recent"))
        #expect(ids[2].contains("old"))
        #expect(ids[3].contains("unread"))
    }

    @Test("按标题排序忽略大小写")
    func sortsByTitle() throws {
        let (store, _) = try makeStore()
        for title in ["banana", "Apple", "cherry"] {
            try store.save(makeEntry(id: title, title: title))
        }
        let titles = try store.entries(sortedBy: .title, categoryID: nil).map(\.manga.title)
        #expect(titles == ["Apple", "banana", "cherry"])
    }

    @Test("按加入时间排序：新的在前")
    func sortsByRecentlyAdded() throws {
        let (store, _) = try makeStore()
        try store.save(makeEntry(id: "a", addedAt: Date(timeIntervalSince1970: 100)))
        try store.save(makeEntry(id: "b", addedAt: Date(timeIntervalSince1970: 300)))
        try store.save(makeEntry(id: "c", addedAt: Date(timeIntervalSince1970: 200)))

        let ids = try store.entries(sortedBy: .recentlyAdded, categoryID: nil).map(\.id)
        #expect(ids.map { $0.suffix(1) } == ["b", "c", "a"])
    }

    @Test("按分类筛选")
    func filtersByCategory() throws {
        let (store, _) = try makeStore()
        try store.save(makeEntry(id: "a", categoryID: "收藏"))
        try store.save(makeEntry(id: "b", categoryID: "待读"))
        try store.save(makeEntry(id: "c"))

        #expect(try store.entries(sortedBy: .title, categoryID: "收藏").count == 1)
        #expect(try store.entries(sortedBy: .title, categoryID: "不存在").isEmpty)
        #expect(try store.entries(sortedBy: .title, categoryID: nil).count == 3)
        #expect(try store.categories().map(\.name) == ["收藏", "待读"], "顺序应为创建顺序")
    }

    // MARK: 组织

    @Test("置顶 / 分类 / 未读数可修改")
    func mutatesOrganization() throws {
        let (store, _) = try makeStore()
        let entry = makeEntry(id: "one")
        try store.save(entry)

        try store.setPinned(mangaID: entry.id, isPinned: true)
        try store.setCategory(mangaID: entry.id, categoryID: "收藏")
        try store.setUnreadCount(mangaID: entry.id, count: 5)

        var loaded = try #require(try store.entry(mangaID: entry.id))
        #expect(loaded.isPinned)
        #expect(loaded.categoryID == "收藏")
        #expect(loaded.unreadCount == 5)

        // 负数未读归零
        try store.setUnreadCount(mangaID: entry.id, count: -3)
        loaded = try #require(try store.entry(mangaID: entry.id))
        #expect(loaded.unreadCount == 0)

        // 取消分类
        try store.setCategory(mangaID: entry.id, categoryID: nil)
        #expect(try store.entry(mangaID: entry.id)?.categoryID == nil)
    }

    @Test("对不存在的条目改组织信息报错", arguments: [0, 1, 2])
    func mutateMissingEntryThrows(kind: Int) throws {
        let (store, _) = try makeStore()
        switch kind {
        case 0:
            expectThrows(LibraryStoreError.entryNotFound("ghost")) {
                try store.setPinned(mangaID: "ghost", isPinned: true)
            }
        case 1:
            expectThrows(LibraryStoreError.entryNotFound("ghost")) {
                try store.setCategory(mangaID: "ghost", categoryID: "x")
            }
        default:
            expectThrows(LibraryStoreError.entryNotFound("ghost")) {
                try store.setUnreadCount(mangaID: "ghost", count: 1)
            }
        }
    }

    // MARK: 进度

    @Test("记录进度会同时更新条目与历史")
    func updateProgressWritesBoth() throws {
        let (store, _) = try makeStore()
        let entry = makeEntry(id: "one")
        try store.save(entry)

        let now = Date(timeIntervalSince1970: 5_000)
        try store.updateProgress(
            mangaID: entry.id,
            chapterID: "ch-1",
            chapterName: "第 1 话",
            pageIndex: 7,
            at: now
        )

        let loaded = try #require(try store.entry(mangaID: entry.id))
        #expect(loaded.lastReadChapterID == "ch-1")
        #expect(loaded.lastReadPageIndex == 7)
        #expect(loaded.lastReadAt == now)

        let history = try store.recentHistory(limit: 10)
        #expect(history.count == 1)
        #expect(history.first?.chapterName == "第 1 话")
        #expect(history.first?.pageIndex == 7)
    }

    @Test("负页码被拒绝")
    func rejectsNegativePageIndex() throws {
        let (store, _) = try makeStore()
        let entry = makeEntry(id: "one")
        try store.save(entry)

        expectThrows(LibraryStoreError.invalidPageIndex(-1)) {
            try store.updateProgress(
                mangaID: entry.id,
                chapterID: "ch",
                chapterName: "ch",
                pageIndex: -1,
                at: Date()
            )
        }
        expectThrows(LibraryStoreError.invalidPageIndex(-5)) {
            try store.recordHistory(
                mangaID: entry.id,
                chapterID: "ch",
                chapterName: "ch",
                pageIndex: -5,
                at: Date()
            )
        }
    }

    @Test("对不存在条目记录进度：抛错且不留历史（事务一致性）")
    func updateProgressIsAtomic() throws {
        let (store, _) = try makeStore()

        expectThrows(LibraryStoreError.entryNotFound("ghost")) {
            try store.updateProgress(
                mangaID: "ghost",
                chapterID: "ch",
                chapterName: "ch",
                pageIndex: 0,
                at: Date()
            )
        }

        // 失败不应留下任何痕迹
        #expect(try store.recentHistory(limit: 10).isEmpty)
        #expect(try store.count() == 0)
    }

    // MARK: 历史

    @Test("同一章节重复记录只保留一条并更新")
    func historyUpserts() throws {
        let (store, _) = try makeStore()
        try store.recordHistory(
            mangaID: "m", chapterID: "c1", chapterName: "旧名", pageIndex: 1,
            at: Date(timeIntervalSince1970: 100)
        )
        try store.recordHistory(
            mangaID: "m", chapterID: "c1", chapterName: "新名", pageIndex: 9,
            at: Date(timeIntervalSince1970: 200)
        )

        let history = try store.recentHistory(limit: 10)
        #expect(history.count == 1)
        #expect(history.first?.chapterName == "新名")
        #expect(history.first?.pageIndex == 9)
    }

    @Test("历史按时间倒序，limit 生效")
    func historyOrderAndLimit() throws {
        let (store, _) = try makeStore()
        for index in 0..<5 {
            try store.recordHistory(
                mangaID: "m",
                chapterID: "c\(index)",
                chapterName: "第 \(index) 话",
                pageIndex: 0,
                at: Date(timeIntervalSince1970: Double(index) * 10)
            )
        }

        let all = try store.recentHistory(limit: 10)
        #expect(all.count == 5)
        #expect(all.first?.chapterID == "c4")
        #expect(all.last?.chapterID == "c0")

        let top2 = try store.recentHistory(limit: 2)
        #expect(top2.map(\.chapterID) == ["c4", "c3"])
    }

    @Test("非法 limit 被拒绝", arguments: [0, -1, -100])
    func rejectsInvalidLimit(limit: Int) throws {
        let (store, _) = try makeStore()
        expectThrows(LibraryStoreError.invalidLimit(limit)) {
            _ = try store.recentHistory(limit: limit)
        }
    }

    @Test("按作品查历史 / 删除单条 / 清空")
    func historyByMangaAndRemoval() throws {
        let (store, _) = try makeStore()
        try store.recordHistory(mangaID: "m1", chapterID: "c1", chapterName: "1", pageIndex: 0, at: Date())
        try store.recordHistory(mangaID: "m1", chapterID: "c2", chapterName: "2", pageIndex: 0, at: Date())
        try store.recordHistory(mangaID: "m2", chapterID: "c1", chapterName: "1", pageIndex: 0, at: Date())

        #expect(try store.history(mangaID: "m1").count == 2)
        #expect(try store.history(mangaID: "m2").count == 1)
        #expect(try store.history(mangaID: "none").isEmpty)

        #expect(try store.removeHistory(mangaID: "m1", chapterID: "c1"))
        #expect(try store.removeHistory(mangaID: "m1", chapterID: "c1") == false)
        #expect(try store.history(mangaID: "m1").count == 1)

        #expect(try store.clearHistory() == 2)
        #expect(try store.recentHistory(limit: 10).isEmpty)
    }

    @Test("裁剪历史只保留最近 N 条")
    func prunesHistory() throws {
        let (store, _) = try makeStore()
        for index in 0..<10 {
            try store.recordHistory(
                mangaID: "m",
                chapterID: "c\(index)",
                chapterName: "\(index)",
                pageIndex: 0,
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        #expect(try store.pruneHistory(keep: 4) == 6)
        let left = try store.recentHistory(limit: 10)
        #expect(left.count == 4)
        #expect(left.first?.chapterID == "c9")
        #expect(left.last?.chapterID == "c6")

        // 已经少于 keep：无操作
        #expect(try store.pruneHistory(keep: 10) == 0)
        // keep = 0 清空
        #expect(try store.pruneHistory(keep: 0) == 4)
        #expect(try store.recentHistory(limit: 10).isEmpty)
        // 负数非法
        expectThrows(LibraryStoreError.invalidLimit(-1)) {
            _ = try store.pruneHistory(keep: -1)
        }
    }

    // MARK: 删除

    @Test("移除条目会连带清理它的历史")
    func removeEntryAlsoRemovesHistory() throws {
        let (store, _) = try makeStore()
        let entry = makeEntry(id: "one")
        try store.save(entry)
        try store.recordHistory(mangaID: entry.id, chapterID: "c1", chapterName: "1", pageIndex: 0, at: Date())

        #expect(try store.remove(mangaID: entry.id))
        #expect(try store.remove(mangaID: entry.id) == false)
        #expect(try store.count() == 0)
        #expect(try store.history(mangaID: entry.id).isEmpty)
    }

    @Test("清空书架返回删除条数")
    func removeAllCounts() throws {
        let (store, _) = try makeStore()
        for index in 0..<3 {
            try store.save(makeEntry(id: "m\(index)"))
        }
        #expect(try store.removeAll() == 3)
        #expect(try store.count() == 0)
        #expect(try store.removeAll() == 0)
    }

    // MARK: 批量与并发

    @Test("批量写入 500 条并按标题读回")
    func handlesLargeBatch() throws {
        let (store, _) = try makeStore()
        for index in 0..<500 {
            try store.save(makeEntry(id: String(format: "%04d", index), title: "作品 \(index)"))
        }
        #expect(try store.count() == 500)

        let all = try store.entries(sortedBy: .title, categoryID: nil)
        #expect(all.count == 500)
        // "作品 0"、"作品 1"、"作品 10"… 的字典序：第 2 项应是 "作品 1"
        #expect(all[1].manga.title == "作品 1")
    }

    @Test("并发写入不丢数据")
    func concurrentWritesAreSafe() async throws {
        let (store, database) = try makeStore()
        _ = database

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try? store.save(self.makeEntry(id: "con-\(index)"))
                }
            }
        }
        #expect(try store.count() == 100)
    }

    @Test("并发读写混合不崩溃且结果自洽")
    func concurrentReadWrite() async throws {
        let (store, _) = try makeStore()
        try store.save(makeEntry(id: "seed"))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try? store.save(self.makeEntry(id: "w-\(index)"))
                    _ = try? store.entries(sortedBy: .lastRead, categoryID: nil)
                    _ = try? store.count()
                    _ = try? store.entry(mangaID: "seed")
                }
            }
        }
        #expect(try store.count() == 51)
    }

    // MARK: 持久化

    @Test("落盘数据库关闭后重新打开数据仍在")
    func persistsAcrossReopen() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }
        let url = directory.appendingPathComponent("library.sqlite")

        let first = try AppDatabase.open(.file(url))
        let firstStore = DatabaseLibraryStore(database: first)
        let entry = makeEntry(id: "persisted", title: "落盘作品")
        try firstStore.save(entry)
        try firstStore.recordHistory(mangaID: entry.id, chapterID: "c1", chapterName: "1", pageIndex: 3, at: Date())
        try first.close()

        let second = try AppDatabase.open(.file(url))
        let secondStore = DatabaseLibraryStore(database: second)
        #expect(try secondStore.count() == 1)
        #expect(try secondStore.entry(mangaID: entry.id)?.manga.title == "落盘作品")
        #expect(try secondStore.recentHistory(limit: 5).first?.pageIndex == 3)
        try second.close()
    }

    @Test("重复打开同一个库不会重复执行迁移")
    func reopenIsIdempotent() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }
        let url = directory.appendingPathComponent("library2.sqlite")

        let first = try AppDatabase.open(.file(url))
        try first.close()
        let second = try AppDatabase.open(.file(url))
        #expect(try second.appliedMigrations() == Migrations.all)
        try second.close()
    }

    // MARK: 损坏数据

    @Test("损坏的 payload 报 corruptRow 而不是崩溃")
    func corruptPayloadIsReported() {
        do {
            _ = try DatabaseLibraryStore.decodeEntry("{ 这不是 JSON }")
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            // reason 里含底层报错文本，只断言错误类别
            if case .corruptRow = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }

        do {
            _ = try DatabaseLibraryStore.decodeHistory("[]")
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            if case .corruptRow = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("解码合法 payload 正常")
    func decodesValidPayload() throws {
        let entry = makeEntry(id: "ok")
        let payload = try DatabaseLibraryStore.encode(entry)
        #expect(try DatabaseLibraryStore.decodeEntry(payload) == entry)

        let history = ReadingHistoryEntry(mangaID: "m", chapterID: "c", chapterName: "n", pageIndex: 2)
        let historyPayload = try DatabaseLibraryStore.encodeHistory(history)
        #expect(try DatabaseLibraryStore.decodeHistory(historyPayload) == history)
    }

    @Test("结构不符的 JSON 解码失败")
    func rejectsStructurallyInvalidPayload() {
        do {
            _ = try DatabaseLibraryStore.decodeEntry("{}")
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            if case .corruptRow = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("corruptRow 的错误码与 AppError 映射")
    func corruptRowMapsToAppError() {
        let error = LibraryStoreError.corruptRow(reason: "坏")
        // 文案本身走 `Copy`（随语言变化），因此断言「原因被带进去了」而不是某句话。
        #expect(error.message.contains("坏"))
        if case .unknown = error.toAppError { } else {
            Issue.record("应映射为 AppError.unknown")
        }
        assertPayload(LibraryStoreError.entryNotFound("x"), contains: "x", mapperCode: "not_found")
        assertPayload(LibraryStoreError.invalidLimit(0), contains: "0", mapperCode: "invalid_input")
        assertPayload(LibraryStoreError.invalidPageIndex(-1), contains: "-1", mapperCode: "invalid_input")
    }

    /// `toAppError` 的 payload 也是**本地化文案**（随设备语言变化），
    /// 所以这里断言两件与语言无关的事：稳定错误码，以及「关键信息被带进去了」。
    private func assertPayload(_ error: LibraryStoreError, contains key: String, mapperCode: String) {
        let appError = error.toAppError
        let payload: String
        switch appError {
        case let .notFound(value), let .invalidInput(value):
            payload = value
        default:
            Issue.record("映射种类不符：\(appError)")
            return
        }
        #expect(appError.code == mapperCode)
        #expect(payload.contains(key))
    }
}

/// 协议一致性：同一批断言跑在**两个实现**上（GRDB 与内存），
/// 保证 `LibraryStoring` 的语义不会在各实现之间漂移。
@Suite("书架协议一致性")
struct LibraryStoreContractTests {

    private func makeStores() throws -> [(name: String, store: any LibraryStoring)] {
        let database = try AppDatabase.open(.memory)
        return [
            ("GRDB", DatabaseLibraryStore(database: database)),
            ("内存", InMemoryLibraryStore())
        ]
    }

    private func makeEntry(id: String, title: String, addedAt: TimeInterval) -> LibraryEntry {
        let manga = Manga(
            sourceID: SourceID("demo"),
            url: "https://example.com/\(id)",
            title: title
        )
        return LibraryEntry(manga: manga, addedAt: Date(timeIntervalSince1970: addedAt))
    }

    /// 单实现（GRDB）——与 `LibraryStoreTests` 里的同名辅助保持一致的返回形态。
    private func makeStore() throws -> (DatabaseLibraryStore, AppDatabase) {
        let database = try AppDatabase.open(.memory)
        return (DatabaseLibraryStore(database: database), database)
    }

    /// 带分类的条目。
    private func makeEntry(id: String, categoryID: String?) -> LibraryEntry {
        let manga = Manga(
            sourceID: SourceID("demo"),
            url: "https://example.com/\(id)",
            title: "作品 \(id)"
        )
        return LibraryEntry(
            manga: manga,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categoryID: categoryID
        )
    }

    /// 无分类的条目。
    private func makeEntry(id: String) -> LibraryEntry {
        makeEntry(id: id, categoryID: nil)
    }

    @Test("两种实现的排序结果一致")
    func sortingMatches() throws {
        for (name, store) in try makeStores() {
            try store.save(makeEntry(id: "b", title: "banana", addedAt: 200))
            try store.save(makeEntry(id: "a", title: "Apple", addedAt: 100))
            try store.save(makeEntry(id: "c", title: "cherry", addedAt: 300))

            let byTitle = try store.entries(sortedBy: .title, categoryID: nil).map(\.manga.title)
            #expect(byTitle == ["Apple", "banana", "cherry"], "实现 \(name) 的标题排序不一致")

            let byAdded = try store.entries(sortedBy: .recentlyAdded, categoryID: nil).map(\.manga.title)
            #expect(byAdded == ["cherry", "banana", "Apple"], "实现 \(name) 的加入时间排序不一致")
        }
    }

    @Test("两种实现的置顶优先与最近阅读排序一致")
    func pinnedAndLastReadMatch() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        for (name, store) in try makeStores() {
            try store.save(makeEntry(id: "unread", title: "U", addedAt: base.timeIntervalSince1970))
            try store.save(makeEntry(id: "read", title: "R", addedAt: base.timeIntervalSince1970))
            try store.save(makeEntry(id: "pinned", title: "P", addedAt: base.timeIntervalSince1970))
            try store.setPinned(mangaID: Manga.makeID(sourceID: SourceID("demo"), url: "https://example.com/pinned"), isPinned: true)
            try store.updateProgress(
                mangaID: Manga.makeID(sourceID: SourceID("demo"), url: "https://example.com/read"),
                chapterID: "c1",
                chapterName: "第 1 话",
                pageIndex: 3,
                at: base
            )

            let titles = try store.entries(sortedBy: .lastRead, categoryID: nil).map(\.manga.title)
            #expect(titles.first == "P", "实现 \(name)：置顶应排在最前")
            #expect(titles[1] == "R", "实现 \(name)：已读应排在未读之前")
            #expect(titles.last == "U", "实现 \(name)：未读应排在最后")
        }
    }

    @Test("两种实现的连带删除一致")
    func cascadeDeleteMatches() throws {
        for (name, store) in try makeStores() {
            let entry = makeEntry(id: "one", title: "One", addedAt: 1)
            try store.save(entry)
            try store.recordHistory(mangaID: entry.id, chapterID: "c1", chapterName: "1", pageIndex: 0, at: Date())

            #expect(try store.remove(mangaID: entry.id), "实现 \(name)：首次删除应成功")
            #expect(try store.remove(mangaID: entry.id) == false, "实现 \(name)：重复删除应返回 false")
            #expect(try store.count() == 0)
            #expect(try store.recentHistory(limit: 10).isEmpty, "实现 \(name)：历史应被连带删除")
        }
    }

    @Test("两种实现的进度写入与错误一致")
    func progressBehaviourMatches() throws {
        for (name, store) in try makeStores() {
            let entry = makeEntry(id: "one", title: "One", addedAt: 1)
            try store.save(entry)

            try store.updateProgress(
                mangaID: entry.id,
                chapterID: "c1",
                chapterName: "第 1 话",
                pageIndex: 5,
                at: Date(timeIntervalSince1970: 9_999)
            )
            let loaded = try store.entry(mangaID: entry.id)
            #expect(loaded?.lastReadPageIndex == 5, "实现 \(name)：进度未写入")
            #expect(loaded?.lastReadChapterID == "c1", "实现 \(name)：章节未写入")
            #expect(try store.recentHistory(limit: 5).count == 1, "实现 \(name)：历史未写入")

            expectThrows(LibraryStoreError.entryNotFound("ghost")) {
                try store.updateProgress(
                    mangaID: "ghost",
                    chapterID: "c",
                    chapterName: "c",
                    pageIndex: 0,
                    at: Date()
                )
            }
            expectThrows(LibraryStoreError.invalidPageIndex(-1)) {
                try store.updateProgress(
                    mangaID: entry.id,
                    chapterID: "c",
                    chapterName: "c",
                    pageIndex: -1,
                    at: Date()
                )
            }
        }
    }

    @Test("两种实现的历史裁剪与清空一致")
    func historyPruningMatches() throws {
        for (name, store) in try makeStores() {
            for index in 0..<5 {
                try store.recordHistory(
                    mangaID: "m",
                    chapterID: "c\(index)",
                    chapterName: "\(index)",
                    pageIndex: 0,
                    at: Date(timeIntervalSince1970: Double(index))
                )
            }
            #expect(try store.pruneHistory(keep: 2) == 3, "实现 \(name)：裁剪数量不一致")
            #expect(try store.recentHistory(limit: 10).count == 2, "实现 \(name)：裁剪后数量不一致")
            #expect(try store.clearHistory() == 2, "实现 \(name)：清空数量不一致")
            expectThrows(LibraryStoreError.invalidLimit(0)) {
                _ = try store.recentHistory(limit: 0)
            }
        }
    }

    @Test("两种实现的分类列举一致")
    func categoriesMatch() throws {
        for (name, store) in try makeStores() {
            var first = makeEntry(id: "a", title: "A", addedAt: 1)
            first.categoryID = "收藏"
            var second = makeEntry(id: "b", title: "B", addedAt: 2)
            second.categoryID = "待读"
            var third = makeEntry(id: "c", title: "C", addedAt: 3)
            third.categoryID = "收藏"
            try store.save(first)
            try store.save(second)
            try store.save(third)

            #expect(try store.categories().map(\.name) == ["收藏", "待读"], "实现 \(name)：分类列举不一致")
            #expect(try store.entries(sortedBy: .title, categoryID: "收藏").count == 2)
        }
    }

    @Test("两种实现的未读数归零行为一致")
    func unreadCountClampingMatches() throws {
        for (name, store) in try makeStores() {
            let entry = makeEntry(id: "a", title: "A", addedAt: 1)
            try store.save(entry)
            try store.setUnreadCount(mangaID: entry.id, count: -7)
            #expect(try store.entry(mangaID: entry.id)?.unreadCount == 0, "实现 \(name)：负数未读未归零")
            try store.setUnreadCount(mangaID: entry.id, count: 12)
            #expect(try store.entry(mangaID: entry.id)?.unreadCount == 12, "实现 \(name)：未读未写入")
        }
    }

    // MARK: 分类（独立实体）

    @Test("空分类也能保存：创建后立即出现在列表里")
    func emptyCategoryPersists() throws {
        for (name, store) in try makeStores() {
            let category = try store.createCategory(name: "追更")
            #expect(category.name == "追更")

            let listed = try store.categories()
            #expect(listed.count == 1, "实现 \(name)：空分类应保留")
            #expect(listed.first?.id == category.id)
            #expect(try store.count() == 0, "创建分类不应影响条目数")
        }
    }

    @Test("分类名会被清洗：首尾与连续空白")
    func categoryNameIsSanitized() throws {
        let (store, _) = try makeStore()
        let category = try store.createCategory(name: "  我的   收藏  ")
        #expect(category.name == "我的 收藏")
    }

    @Test("超长分类名被截断")
    func categoryNameIsTruncated() throws {
        let (store, _) = try makeStore()
        let category = try store.createCategory(name: String(repeating: "长", count: 200))
        #expect(category.name.count == 60)
    }

    @Test("空分类名被拒绝", arguments: ["", "   ", "\n\t "])
    func rejectsBlankCategoryName(name: String) throws {
        let (store, _) = try makeStore()
        do {
            _ = try store.createCategory(name: name)
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            guard case .invalidCategoryName = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("重名分类被拒绝（忽略空白与大小写）")
    func rejectsDuplicateCategoryName() throws {
        let (store, _) = try makeStore()
        _ = try store.createCategory(name: "收藏")
        _ = try store.createCategory(name: "Favorites")

        for duplicate in [" 收藏 ", "收藏", "favorites", " Favorites "] {
            do {
                _ = try store.createCategory(name: duplicate)
                Issue.record("「\(duplicate)」应被判为重名")
            } catch let error as LibraryStoreError {
                guard case .duplicateCategoryName = error else {
                    Issue.record("错误类型不符：\(error)")
                    return
                }
            }
        }
    }

    @Test("重命名：id 不变、条目引用不受影响")
    func renameKeepsReferences() throws {
        for (name, store) in try makeStores() {
            let category = try store.createCategory(name: "旧名")
            let entry = makeEntry(id: "a", categoryID: category.id)
            try store.save(entry)

            let renamed = try store.renameCategory(id: category.id, to: "新名")
            #expect(renamed.id == category.id)
            #expect(renamed.name == "新名")

            #expect(
                try store.entry(mangaID: entry.id)?.categoryID == category.id,
                "实现 \(name)：重命名不应改变条目引用"
            )
            #expect(try store.categories().first?.name == "新名")
        }
    }

    @Test("重命名允许改自己的大小写，但不允许撞别的分类")
    func renameAllowsSelfButRejectsOthers() throws {
        let (store, _) = try makeStore()
        let a = try store.createCategory(name: "Alpha")
        _ = try store.createCategory(name: "Beta")

        let same = try store.renameCategory(id: a.id, to: "alpha")
        #expect(same.name == "alpha")

        do {
            _ = try store.renameCategory(id: a.id, to: "Beta")
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            guard case .duplicateCategoryName = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("重命名不存在的分类抛 categoryNotFound")
    func renameMissingCategory() throws {
        let (store, _) = try makeStore()
        do {
            _ = try store.renameCategory(id: "ghost", to: "x")
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            guard case .categoryNotFound = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("删除分类：条目移出但不被删除")
    func deleteCategoryKeepsEntries() throws {
        for (name, store) in try makeStores() {
            _ = try store.createCategory(name: "收藏")
            let categoryID = try #require(try store.categories().first?.id)
            let entryA = makeEntry(id: "a", categoryID: categoryID)
            let entryB = makeEntry(id: "b", categoryID: categoryID)
            try store.save(entryA)
            try store.save(entryB)
            try store.save(makeEntry(id: "c"))

            let affected = try store.deleteCategory(id: categoryID)
            #expect(affected == 2, "实现 \(name)：应报告 2 条受影响")

            #expect(try store.categories().isEmpty)
            #expect(try store.count() == 3, "条目本身应保留")
            #expect(try store.entry(mangaID: entryA.id)?.categoryID == nil)
            #expect(try store.entry(mangaID: entryB.id)?.categoryID == nil)
            #expect(try store.entries(sortedBy: .title, categoryID: categoryID).isEmpty)
        }
    }

    @Test("删除不存在的分类抛 categoryNotFound")
    func deleteMissingCategory() throws {
        let (store, _) = try makeStore()
        do {
            _ = try store.deleteCategory(id: "ghost")
            Issue.record("应当抛错")
        } catch let error as LibraryStoreError {
            guard case .categoryNotFound = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("重排分类：给定顺序生效，未列出的保持相对顺序排在后")
    func reorderCategories() throws {
        for (name, store) in try makeStores() {
            let a = try store.createCategory(name: "A")
            let b = try store.createCategory(name: "B")
            let c = try store.createCategory(name: "C")

            try store.reorderCategories([c.id, a.id])
            #expect(
                try store.categories().map(\.name) == ["C", "A", "B"],
                "实现 \(name)：未列出的分类应排在后"
            )

            try store.reorderCategories([b.id, "ghost", b.id, c.id])
            #expect(
                try store.categories().map(\.name) == ["B", "C", "A"],
                "实现 \(name)：非法与重复 id 应被忽略"
            )
        }
    }

    @Test("save 引用未登记的分类时自动补建，避免孤立引用")
    func saveBackfillsCategory() throws {
        for (name, store) in try makeStores() {
            let entry = makeEntry(id: "a", categoryID: "临时分类")
            try store.save(entry)

            let listed = try store.categories()
            #expect(listed.map(\.name) == ["临时分类"], "实现 \(name)：应自动补建分类")
            #expect(try store.entry(mangaID: entry.id)?.categoryID == listed.first?.id)
        }
    }

    @Test("setCategory 同样补建分类；设为 nil 只是移出条目")
    func setCategoryBackfills() throws {
        for (name, store) in try makeStores() {
            let entry = makeEntry(id: "a")
            try store.save(entry)
            try store.setCategory(mangaID: entry.id, categoryID: "稍后读")
            #expect(try store.categories().count == 1, "实现 \(name)：应补建分类")
            #expect(try store.entry(mangaID: entry.id)?.categoryID != nil)

            try store.setCategory(mangaID: entry.id, categoryID: nil)
            #expect(try store.entry(mangaID: entry.id)?.categoryID == nil)
            #expect(try store.categories().count == 1, "实现 \(name)：移出分类不应删掉分类本身")
        }
    }

    @Test("分类落盘后重启仍在")
    func categoriesPersist() throws {
        let dir = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(dir) }
        let file = dir.appendingPathComponent("lib.sqlite", isDirectory: false)

        let first = DatabaseLibraryStore(database: try AppDatabase.open(.file(file)))
        let created = try first.createCategory(name: "常年追")
        let entry = makeEntry(id: "a", categoryID: created.id)
        try first.save(entry)
        _ = try first.createCategory(name: "空分类")

        let second = DatabaseLibraryStore(database: try AppDatabase.open(.file(file)))
        #expect(try second.categories().map(\.name) == ["常年追", "空分类"])
        #expect(try second.entry(mangaID: entry.id)?.categoryID == created.id)
    }
}
