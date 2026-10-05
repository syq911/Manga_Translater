//
//  ModelTests.swift
//  MangaTranslaterTests
//
//  覆盖 AppCore 模型与校验：稳定 ID 派生、字段清洗、URL / 来源 ID / 版本号校验。
//

import Testing
import Foundation
import AppCore

@Suite("数据模型与校验")
struct ModelTests {

    // MARK: 稳定 ID

    @Test("作品 ID 由来源与地址稳定派生")
    func mangaIDIsStable() {
        let first = Manga(sourceID: .local, url: "/books/one.cbz", title: "One")
        let second = Manga(sourceID: .local, url: "/books/one.cbz", title: "One（改名）")

        #expect(first.id == second.id)
        #expect(first.id == "local|/books/one.cbz")
    }

    @Test("不同来源的同名地址产生不同 ID")
    func differentSourcesProduceDifferentIDs() {
        let a = Manga(sourceID: SourceID("alpha"), url: "https://x.test/1", title: "T")
        let b = Manga(sourceID: SourceID("beta"), url: "https://x.test/1", title: "T")
        #expect(a.id != b.id)
    }

    @Test("章节 ID 由作品与地址派生")
    func chapterIDIsStable() {
        let chapter = Chapter(mangaID: "local|/a.cbz", url: "ch/1", name: "第 1 话")
        #expect(chapter.id == "local|/a.cbz|ch/1")
        #expect(chapter.chapterNumber == nil)
    }

    // MARK: URL 校验

    @Test("合法 HTTPS 地址通过")
    func acceptsHTTPS() {
        #expect(ModelValidation.isValidURLString("https://example.com/path?q=1"))
        #expect(ModelValidation.isValidURLString("  https://example.com  "))
    }

    @Test("http 仅允许本机地址")
    func httpOnlyForLocalhost() {
        #expect(ModelValidation.isValidURLString("http://localhost:8080/api"))
        #expect(ModelValidation.isValidURLString("http://127.0.0.1/api"))
        #expect(!ModelValidation.isValidURLString("http://example.com"))
    }

    @Test("非法地址被拒绝", arguments: [
        "",
        "   ",
        "example.com",
        "ftp://example.com",
        "javascript:alert(1)",
        "https://exa mple.com",
        "https:///path",
        "file:///etc/passwd",
    ])
    func rejectsInvalidURLs(value: String) {
        #expect(!ModelValidation.isValidURLString(value))
    }

    // MARK: 标题清洗

    @Test("标题折叠空白并去首尾空格")
    func sanitizesTitle() {
        #expect(ModelValidation.sanitizeTitle("  a   b \n c ") == "a b c")
    }

    @Test("超长标题被截断到上限")
    func truncatesLongTitle() {
        let long = String(repeating: "あ", count: 500)
        let sanitized = ModelValidation.sanitizeTitle(long, maxLength: 300)
        #expect(sanitized.count == 300)
    }

    @Test("仅空白的标题清洗后为空串")
    func sanitizesBlankTitle() {
        #expect(ModelValidation.sanitizeTitle("   \n\t ").isEmpty)
    }

    // MARK: 来源 ID

    @Test("合法来源 ID 通过", arguments: ["a", "abc", "a1", "my-source", "my_source", "source2026"])
    func acceptsValidSourceIDs(value: String) {
        #expect(ModelValidation.isValidSourceID(value))
    }

    @Test("非法来源 ID 被拒绝", arguments: [
        "",
        "-leading",
        "_leading",
        "Has Upper",
        "with space",
        "with/slash",
        "with.dot",
        "中文",
        String(repeating: "a", count: 65),
    ])
    func rejectsInvalidSourceIDs(value: String) {
        #expect(!ModelValidation.isValidSourceID(value))
    }

    // MARK: 版本号

    @Test("合法版本号通过", arguments: ["1", "1.2", "1.2.3", "1.2.3-beta.1", "0.1.0"])
    func acceptsVersions(value: String) {
        #expect(ModelValidation.isValidVersionString(value))
    }

    @Test("非法版本号被拒绝", arguments: ["", "v1", "1.", "1.2.3.4.5", "abc", "1.2.3-"])
    func rejectsVersions(value: String) {
        #expect(!ModelValidation.isValidVersionString(value))
    }

    // MARK: 序列化

    @Test("模型可 JSON 往返")
    func codableRoundTrip() throws {
        let manga = Manga(
            sourceID: SourceID("demo"),
            url: "https://x.test/1",
            title: "标题",
            author: "作者",
            genres: ["a", "b"],
            status: .ongoing,
            coverURL: "https://x.test/1.jpg"
        )
        let data = try JSONEncoder().encode(manga)
        let decoded = try JSONDecoder().decode(Manga.self, from: data)
        #expect(decoded == manga)
        #expect(decoded.id == manga.id)
    }

    @Test("分页空值常量正确")
    func emptyPageDefaults() {
        #expect(MangaListPage.empty.items.isEmpty)
        #expect(MangaListPage.empty.hasNextPage == false)
    }

    @Test("来源元信息默认值合理")
    func sourceMetaDefaults() {
        let meta = SourceMeta(id: SourceID("demo"), name: "Demo")
        #expect(meta.kind == .remote)
        #expect(meta.isNSFW == false)
        #expect(meta.rateLimitMilliseconds == 0)
        #expect(meta.language == "all")
    }
}
