//
//  DownloadArchiveStoreTests.swift
//  MangaTranslaterTests
//
//  归档存储：写 CBZ、读回单页、列表与统计、删除、命名健壮性。
//
//  这些用例不碰网络，也不碰 JS——归档是纯文件系统行为，
//  它的正确性可以直接被断言钉死。
//

import Foundation
import Testing
import AppCore
import ComicDownload

@Suite("下载归档存储")
struct DownloadArchiveStoreTests {

    private func makeStore() throws -> (DownloadArchiveStore, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        return (DownloadArchiveStore(rootDirectory: root), root)
    }

    private func pages(_ count: Int, bytes: String = "page") -> [CbzPage] {
        (0..<count).map { index in
            CbzPage(index: index, data: Data("\(bytes)-\(index)".utf8))
        }
    }

    // MARK: 基本写入与查询

    @Test("归档后能查到、能统计、能读回每一页")
    func archivesAndReadsBack() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        let record = try store.archive(
            pages: pages(3),
            mangaID: "demo|https://example.com/m/1",
            chapterID: "demo|https://example.com/m/1|https://example.com/c/1",
            chapterName: "第 1 话"
        )

        #expect(record.pageCount == 3)
        #expect(record.byteCount > 0)
        #expect(store.hasChapter(mangaID: record.mangaID, chapterID: record.chapterID))
        #expect(store.chapter(mangaID: record.mangaID, chapterID: record.chapterID)?.chapterName == "第 1 话")
        #expect(store.chapters(mangaID: record.mangaID).count == 1)
        #expect(store.allChapters().count == 1)
        #expect(store.totalBytes() == record.byteCount)
        #expect(store.pageCount(mangaID: record.mangaID, chapterID: record.chapterID) == 3)

        for index in 0..<3 {
            let data = store.pageData(
                mangaID: record.mangaID,
                chapterID: record.chapterID,
                pageIndex: index
            )
            #expect(data == Data("page-\(index)".utf8))
        }
    }

    @Test("未归档的查询一律返回「没有」，不抛错")
    func missingArchiveIsQuiet() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        #expect(store.hasChapter(mangaID: "a", chapterID: "b") == false)
        #expect(store.chapter(mangaID: "a", chapterID: "b") == nil)
        #expect(store.chapters(mangaID: "a").isEmpty)
        #expect(store.allChapters().isEmpty)
        #expect(store.totalBytes() == 0)
        #expect(store.pageData(mangaID: "a", chapterID: "b", pageIndex: 0) == nil)
        #expect(store.pageCount(mangaID: "a", chapterID: "b") == nil)
    }

    @Test("页号越界与负数返回 nil（调用方据此回落网络）")
    func outOfRangePageIsNil() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        let record = try store.archive(
            pages: pages(2),
            mangaID: "m",
            chapterID: "c",
            chapterName: "c"
        )
        #expect(store.pageData(mangaID: record.mangaID, chapterID: "c", pageIndex: 2) == nil)
        #expect(store.pageData(mangaID: record.mangaID, chapterID: "c", pageIndex: -1) == nil)
    }

    @Test("非 jpg 扩展名的页也能按序读回")
    func supportsOtherImageExtensions() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        // 图床给 webp / png 是常态；如果按固定 `.jpg` 去找会整章读不出来
        let mixed = [
            CbzPage(index: 0, data: Data("a".utf8), fileExtension: "png"),
            CbzPage(index: 1, data: Data("b".utf8), fileExtension: "webp"),
            CbzPage(index: 2, data: Data("c".utf8), fileExtension: "jpg"),
        ]
        let record = try store.archive(pages: mixed, mangaID: "m", chapterID: "c", chapterName: "c")
        #expect(record.pageCount == 3)
        #expect(store.pageData(mangaID: "m", chapterID: "c", pageIndex: 0) == Data("a".utf8))
        #expect(store.pageData(mangaID: "m", chapterID: "c", pageIndex: 1) == Data("b".utf8))
        #expect(store.pageData(mangaID: "m", chapterID: "c", pageIndex: 2) == Data("c".utf8))
    }

    @Test("空页列表拒绝归档")
    func rejectsEmptyPages() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        #expect(throws: CbzExportError.noPages) {
            _ = try store.archive(pages: [], mangaID: "m", chapterID: "c", chapterName: "c")
        }
    }

    @Test("重复归档同一章会整章替换，不残留旧页")
    func rearchiveReplacesOldPages() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        _ = try store.archive(pages: pages(5), mangaID: "m", chapterID: "c", chapterName: "c")
        _ = try store.archive(pages: pages(2), mangaID: "m", chapterID: "c", chapterName: "c")

        // 页数从 5 变 2：若旧文件只是覆盖同名文件，第 5 页会残留下来
        #expect(store.pageCount(mangaID: "m", chapterID: "c") == 2)
        #expect(store.chapters(mangaID: "m").count == 1)
        #expect(store.pageData(mangaID: "m", chapterID: "c", pageIndex: 2) == nil)
    }

    // MARK: 命名

    @Test("主键里的 / : | 等字符不会产生子目录")
    func sanitizesUnsafeCharacters() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        let mangaID = "demo|https://example.com/a/b?x=1"
        let record = try store.archive(pages: pages(1), mangaID: mangaID, chapterID: mangaID, chapterName: "c")

        let url = store.archiveURL(mangaID: mangaID, chapterID: mangaID)
        // 归档必须正好在「根目录/作品目录」下两层，多一层说明主键被当成路径了
        let relative = url.pathComponents.suffix(3)
        #expect(relative.count == 3)
        #expect(store.hasChapter(mangaID: mangaID, chapterID: record.chapterID))
    }

    @Test("不同主键不撞名，同一主键每次得到同一文件名")
    func namesAreUniqueAndStable() {
        let a = DownloadArchiveStore.fileNameSegment("demo|https://a.example.com/1/chapter")
        let b = DownloadArchiveStore.fileNameSegment("demo|https://b.example.com/1/chapter")
        let c = DownloadArchiveStore.fileNameSegment("demo|https://a.example.com/1/chapter")

        #expect(a != b)
        #expect(a == c)

        // 只用符号组成的主键不能产生空文件名
        #expect(DownloadArchiveStore.fileNameSegment("|||").isEmpty == false)
        // 超长主键要截断，否则 iOS 的文件名上限（255 字节）会写失败
        let long = DownloadArchiveStore.fileNameSegment(String(repeating: "中", count: 400))
        #expect(long.utf8.count < 200)
    }

    @Test("稳定哈希与运行时无关（同一输入永远同一结果）")
    func stableHashIsDeterministic() {
        // 用 `String.hashValue` 的话每次进程启动都会变，文件写完下次就找不到
        #expect(DownloadArchiveStore.stableHash("abc") == DownloadArchiveStore.stableHash("abc"))
        #expect(DownloadArchiveStore.stableHash("abc") != DownloadArchiveStore.stableHash("abd"))
        #expect(DownloadArchiveStore.stableHash("abc").count == 8)
    }

    // MARK: 清单

    @Test("清单带上作品标题，读回来还在")
    func manifestCarriesMangaTitle() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        let record = try store.archive(
            pages: pages(1),
            mangaID: "m",
            chapterID: "c",
            chapterName: "第 1 话",
            mangaTitle: "示例作品"
        )
        #expect(record.mangaTitle == "示例作品")
        #expect(store.chapters(mangaID: "m").first?.mangaTitle == "示例作品")
    }

    @Test("老清单（没有作品标题字段）仍能读出来 —— 不能因为加字段让已有下载全部失效")
    func toleratesManifestWithoutMangaTitle() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.archive(pages: pages(1), mangaID: "m", chapterID: "c", chapterName: "第 1 话")

        // 手写一份「M3 之前」的清单（没有 mangaTitle 这个键）
        let manifest = store.archiveURL(mangaID: "m", chapterID: "c")
            .deletingPathExtension()
            .appendingPathExtension("json")
        let legacy = """
        {"mangaID":"m","chapterID":"c","chapterName":"第 1 话","pageCount":1,\
        "byteCount":1234,"archivedAt":0}
        """
        try Data(legacy.utf8).write(to: manifest)

        let loaded = store.chapters(mangaID: "m")
        #expect(loaded.count == 1)
        #expect(loaded.first?.mangaTitle == nil)
        #expect(loaded.first?.chapterName == "第 1 话")
        // 归档本体与清单是分开的，所以清单字段缺了也不影响读页
        #expect(store.pageData(mangaID: "m", chapterID: "c", pageIndex: 0) != nil)
    }

    // MARK: 删除

    @Test("删除单章后其余章节不受影响，空目录会被清掉")
    func removesSingleChapter() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        _ = try store.archive(pages: pages(1), mangaID: "m", chapterID: "c1", chapterName: "c1")
        _ = try store.archive(pages: pages(1), mangaID: "m", chapterID: "c2", chapterName: "c2")

        #expect(store.removeChapter(mangaID: "m", chapterID: "c1"))
        #expect(store.hasChapter(mangaID: "m", chapterID: "c1") == false)
        #expect(store.hasChapter(mangaID: "m", chapterID: "c2"))
        #expect(store.chapters(mangaID: "m").count == 1)

        #expect(store.removeChapter(mangaID: "m", chapterID: "c2"))
        // 目录空了应该被删掉，而不是留下一个空壳
        let directory = store.archiveURL(mangaID: "m", chapterID: "c2").deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
        // 删不存在的章返回 false 而不是抛错
        #expect(store.removeChapter(mangaID: "m", chapterID: "c2") == false)
    }

    @Test("删除整部与清空全部返回正确条数")
    func removesByMangaAndAll() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        _ = try store.archive(pages: pages(1), mangaID: "m1", chapterID: "c1", chapterName: "c1")
        _ = try store.archive(pages: pages(1), mangaID: "m1", chapterID: "c2", chapterName: "c2")
        _ = try store.archive(pages: pages(1), mangaID: "m2", chapterID: "c3", chapterName: "c3")

        #expect(store.removeManga(mangaID: "m1") == 2)
        #expect(store.allChapters().count == 1)
        #expect(store.removeAll() == 1)
        #expect(store.allChapters().isEmpty)
        #expect(store.removeAll() == 0)
    }
}
