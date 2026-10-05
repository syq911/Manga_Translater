//
//  CoverThumbnailCacheTests.swift
//  MangaTranslaterTests
//
//  书架封面缩略图缓存测试。
//
//  夹具是**真实 PNG**（由外部实现生成并 base64 内联）——不是伪图片头，
//  因为本类职责就是「把真图片缩放成缩略图」，用假数据等于没测。
//
//  覆盖：文件名派生、等比缩放（含不放大与非法尺寸）、
//  正常生成、非图片被拒、内存/磁盘命中、损坏数据不落盘、
//  缓存清理、并发取值。
//

import Testing
import Foundation
import UIKit
@testable import MangaTranslater

@Suite("封面缩略图缓存")
struct CoverThumbnailCacheTests {

    /// 真实 PNG 夹具（8x8 纯色，74 字节），由外部实现生成。
    static let redSquarePNG = Data(
        base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR42mO4Y2ODFTEMLQkA
        XrdVAaRBiusAAAAASUVORK5CYII=
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 真实 PNG 夹具（100x200 竖图，349 字节），由外部实现生成。
    static let tallPNG = Data(
        base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAGQAAADICAIAAACRXtOWAAABJElEQVR42u3QAQ0AAAgDoAcz
        mGENY4UHYCMBmT1KUSBLlixZsmQpkCVLlixZshTIkiVLlixZCmTJkiVLliwFsmTJkiVLlgJZ
        smTJkiVLgSxZsmTJkqVAlixZsmTJUiBLlixZsmQpkCVLlixZshTIkiVLlixZCmTJkiVLliwF
        smTJkiVLlgJZsmTJkiVLgSxZsmTJkqVAlixZsmTJUiBLlixZsmQpkCVLlixZshTIkiVLlixZ
        CmTJkiVLliwFsmTJkiVLlgJZsmTJkiVLgSxZsmTJkqVAlixZsmTJUiBLlixZsmQpkCVLlixZ
        shTIkiVLlixZCmTJkiVLliwFsmTJkiVLlgJZsmTJkiVLgSxZsmTJkqVAlixZsmTJUiBLlixZ
        smQp6D2pkxknE0DqUAAAAABJRU5ErkJggg==
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 真实 PNG 夹具（200x100 横图，261 字节），由外部实现生成。
    static let widePNG = Data(
        base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAMgAAABkCAIAAABM5OhcAAAAzElEQVR42u3SMQ0AAAgEsReG
        MCQiCxMMDE2q4HKpaTgXCTAWxsJYYCyMhbHAWBgLY4GxMBbGAmNhLIwFxsJYGAuMhbEwFhgL
        Y2EsMBbGwlhgLIyFscBYGAtjgbEwFsYCY2EsjAXGwlgYC4yFsTAWGAtjYSwwFsbCWGAsjIWx
        wFgYC2OBsTAWxgJjYSyMBcbCWBgLjIWxMBYYC2NhLDAWxsJYYCyMhbHAWBgLY4GxMBbGAmNh
        LIyFsVTAWBgLY4GxMBbGAmNhLIwFxuK3BaOW/j4ZH//kAAAAAElFTkSuQmCC
        """,
        options: .ignoreUnknownCharacters
    )!

    private func makeCache(maxPixel: CGFloat = 512) throws -> (CoverThumbnailCache, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        return (CoverThumbnailCache(dataDirectory: root, maxPixel: maxPixel), root)
    }

    // MARK: 夹具自检

    @Test("内联 PNG 夹具本身可解码（防止生成器写坏）")
    func fixturesAreRealImages() throws {
        for (name, data, expected) in [
            ("redSquare", Self.redSquarePNG, CGSize(width: 8, height: 8)),
            ("tall", Self.tallPNG, CGSize(width: 100, height: 200)),
            ("wide", Self.widePNG, CGSize(width: 200, height: 100)),
        ] {
            let image = try #require(UIImage(data: data), "夹具 \(name) 应为有效 PNG")
            #expect(image.size == expected, "夹具 \(name) 尺寸不符")
        }
    }

    // MARK: 文件名派生

    @Test("文件名由作品 ID 派生：稳定、无非法字符")
    func fileNameIsStableAndSafe() {
        let id = "local|LocalLibrary/我的作品 [汉化组]-abcd1234.cbz"
        let first = CoverThumbnailCache.fileName(for: id)

        #expect(first == CoverThumbnailCache.fileName(for: id), "同一 ID 必须得到同一文件名")
        #expect(first.hasSuffix(".jpg"))
        #expect(first.count == 16 + 4)
        for bad in ["/", "|", " ", "\n", "["] {
            #expect(!first.contains(bad), "文件名不应包含 \(bad)")
        }
    }

    @Test("不同作品 ID 得到不同文件名")
    func fileNameDiffersPerManga() {
        let a = CoverThumbnailCache.fileName(for: "local|LocalLibrary/book-a.cbz")
        let b = CoverThumbnailCache.fileName(for: "local|LocalLibrary/book-b.cbz")
        #expect(a != b)
    }

    @Test("文件名大小写不敏感冲突：仅差一个字符也会区分")
    func fileNameIsCaseSensitive() {
        #expect(CoverThumbnailCache.fileName(for: "book") != CoverThumbnailCache.fileName(for: "Book"))
    }

    // MARK: 尺寸计算

    @Test("竖图按最长边等比缩放")
    func sizeScalesTall() {
        let size = CoverThumbnailCache.thumbnailSize(
            forPixelSize: CGSize(width: 100, height: 200), maxPixel: 64
        )
        #expect(size == CGSize(width: 32, height: 64))
    }

    @Test("横图按最长边等比缩放")
    func sizeScalesWide() {
        let size = CoverThumbnailCache.thumbnailSize(
            forPixelSize: CGSize(width: 200, height: 100), maxPixel: 64
        )
        #expect(size == CGSize(width: 64, height: 32))
    }

    @Test("正方形按最长边等比缩放")
    func sizeScalesSquare() {
        let size = CoverThumbnailCache.thumbnailSize(
            forPixelSize: CGSize(width: 1000, height: 1000), maxPixel: 100
        )
        #expect(size == CGSize(width: 100, height: 100))
    }

    @Test("小于上限时不放大")
    func sizeDoesNotUpscale() {
        let original = CGSize(width: 8, height: 8)
        #expect(CoverThumbnailCache.thumbnailSize(forPixelSize: original, maxPixel: 512) == original)
    }

    @Test("恰好等于上限时保持不变（不缩放也不放大）")
    func sizeAtExactBoundary() {
        let original = CGSize(width: 512, height: 256)
        #expect(CoverThumbnailCache.thumbnailSize(forPixelSize: original, maxPixel: 512) == original)
    }

    @Test("超长条图缩放后最短边至少 1 像素", arguments: [
        (1000.0, 1.0), (1.0, 1000.0), (10000.0, 3.0),
    ])
    func sizeKeepsAtLeastOnePixel(width: Double, height: Double) {
        let size = CoverThumbnailCache.thumbnailSize(
            forPixelSize: CGSize(width: width, height: height), maxPixel: 64
        )
        #expect(size.width >= 1)
        #expect(size.height >= 1)
        #expect(max(size.width, size.height) <= 64)
    }

    @Test("非法尺寸返回 zero", arguments: [(0.0, 10.0), (10.0, 0.0), (-1.0, 5.0), (0.0, 0.0)])
    func sizeRejectsInvalidInput(width: Double, height: Double) {
        let size = CoverThumbnailCache.thumbnailSize(
            forPixelSize: CGSize(width: width, height: height), maxPixel: 64
        )
        #expect(size == .zero)
    }

    @Test("上限为 0 或负数时返回 zero")
    func sizeRejectsInvalidMaxPixel() {
        #expect(CoverThumbnailCache.thumbnailSize(forPixelSize: CGSize(width: 10, height: 10), maxPixel: 0) == .zero)
        #expect(CoverThumbnailCache.thumbnailSize(forPixelSize: CGSize(width: 10, height: 10), maxPixel: -8) == .zero)
    }

    // MARK: 生成缩略图

    @Test("从竖图生成缩略图：可再次解码且保持比例")
    func generatesThumbnailFromTall() throws {
        let data = try #require(CoverThumbnailCache.makeThumbnail(from: Self.tallPNG, maxPixel: 64))
        let image = try #require(UIImage(data: data), "产物应是可解码的 JPEG")
        #expect(max(image.size.width, image.size.height) <= 64)
        #expect(image.size.height > image.size.width, "竖图比例应保持")
    }

    @Test("从横图生成缩略图")
    func generatesThumbnailFromWide() throws {
        let data = try #require(CoverThumbnailCache.makeThumbnail(from: Self.widePNG, maxPixel: 64))
        let image = try #require(UIImage(data: data))
        #expect(max(image.size.width, image.size.height) <= 64)
        #expect(image.size.width > image.size.height, "横图比例应保持")
    }

    @Test("小图不放大：生成结果仍是原尺寸")
    func smallImageIsNotUpscaled() throws {
        let data = try #require(CoverThumbnailCache.makeThumbnail(from: Self.redSquarePNG, maxPixel: 512))
        let image = try #require(UIImage(data: data))
        #expect(image.size == CGSize(width: 8, height: 8))
    }

    @Test("非图片数据返回 nil 而不崩溃", arguments: ["这不是图片".data(using: .utf8)!, Data(), Data([0x00, 0x01, 0x02])])
    func rejectsNonImageData(data: Data) {
        #expect(CoverThumbnailCache.makeThumbnail(from: data, maxPixel: 64) == nil)
    }

    // MARK: 缓存行为

    @Test("首次生成并落盘；新建实例可命中磁盘缓存（无需原图）")
    func cachesToDiskAndHitsOnSecondInstance() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let mangaID = "local|LocalLibrary/book-abcd1234.cbz"
        var loadCount = 0
        let generated = try #require(cache.thumbnail(mangaID: mangaID) {
            loadCount += 1
            return Self.tallPNG
        })
        #expect(loadCount == 1)
        #expect(FileManager.default.fileExists(atPath: cache.fileURL(mangaID: mangaID).path))

        // 同一实例第二次：命中内存，不再调用 load
        let second = try #require(cache.thumbnail(mangaID: mangaID) {
            loadCount += 1
            return Self.tallPNG
        })
        #expect(second == generated)
        #expect(loadCount == 1, "内存命中不应再取原图")

        // 新实例：内存为空，应命中磁盘；load 返回 nil 也能拿到结果
        let fresh = CoverThumbnailCache(dataDirectory: root)
        let fromDisk = try #require(fresh.thumbnail(mangaID: mangaID) { nil })
        #expect(fromDisk == generated)
    }

    @Test("cachedThumbnail 不触发生成")
    func cachedLookupDoesNotGenerate() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let mangaID = "local|LocalLibrary/none.cbz"
        #expect(cache.cachedThumbnail(mangaID: mangaID) == nil)

        _ = cache.thumbnail(mangaID: mangaID) { Self.widePNG }
        #expect(cache.cachedThumbnail(mangaID: mangaID) != nil)
    }

    @Test("原图缺失时返回 nil，且不留下缓存文件")
    func missingOriginalLeavesNoCacheFile() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let mangaID = "local|LocalLibrary/missing.cbz"
        #expect(cache.thumbnail(mangaID: mangaID) { nil } == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(mangaID: mangaID).path))
    }

    @Test("原图取出时抛错时返回 nil 而不向上抛")
    func loadThrowingIsSwallowed() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        struct Boom: Error {}
        let result = cache.thumbnail(mangaID: "x") { throw Boom() }
        #expect(result == nil)
    }

    @Test("损坏图片不写入缓存（避免下次直接命中坏数据）")
    func corruptImageIsNotCached() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let mangaID = "local|LocalLibrary/corrupt.cbz"
        let broken = Data(Self.tallPNG.prefix(40))   // 截断的 PNG
        #expect(cache.thumbnail(mangaID: mangaID) { broken } == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(mangaID: mangaID).path))
    }

    @Test("多个作品的缓存互不干扰")
    func multipleMangaAreIndependent() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let tallID = "local|LocalLibrary/tall.cbz"
        let wideID = "local|LocalLibrary/wide.cbz"
        let tallThumb = try #require(cache.thumbnail(mangaID: tallID) { Self.tallPNG })
        let wideThumb = try #require(cache.thumbnail(mangaID: wideID) { Self.widePNG })

        #expect(tallThumb != wideThumb)
        let tallImage = try #require(UIImage(data: tallThumb))
        let wideImage = try #require(UIImage(data: wideThumb))
        #expect(tallImage.size.height > wideImage.size.height)
    }

    @Test("removeAll 清空内存与磁盘")
    func removeAllClearsCaches() throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let mangaID = "local|LocalLibrary/clear.cbz"
        _ = try #require(cache.thumbnail(mangaID: mangaID) { Self.tallPNG })
        #expect(cache.cachedThumbnail(mangaID: mangaID) != nil)

        let removed = cache.removeAll()
        #expect(removed >= 1)
        #expect(cache.cachedThumbnail(mangaID: mangaID) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(mangaID: mangaID).path))
    }

    @Test("目录不存在时也能工作（首次使用自动创建）")
    func createsDirectoryOnDemand() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let nested = root.appendingPathComponent("deep/nested/data", isDirectory: true)
        let cache = CoverThumbnailCache(dataDirectory: nested)
        let mangaID = "local|LocalLibrary/nested.cbz"
        _ = try #require(cache.thumbnail(mangaID: mangaID) { Self.tallPNG })
        #expect(FileManager.default.fileExists(atPath: cache.fileURL(mangaID: mangaID).path))
    }

    // MARK: 并发

    @Test("并发取多个作品的封面：全部成功且互不串数据")
    func concurrentThumbnails() async throws {
        let (cache, root) = try makeCache(maxPixel: 64)
        defer { TestFileSystem.remove(root) }

        let ids = (0..<12).map { "local|LocalLibrary/book-\($0).cbz" }
        let results = await withTaskGroup(of: (String, Data?).self) { group in
            for id in ids {
                group.addTask {
                    (id, cache.thumbnail(mangaID: id) { id.hasSuffix("0.cbz") ? Self.tallPNG : Self.widePNG })
                }
            }
            var collected: [String: Data?] = [:]
            for await (id, data) in group { collected[id] = data }
            return collected
        }

        #expect(results.count == ids.count)
        for id in ids {
            #expect(results[id] != nil, "\(id) 应出现在结果里")
            #expect((results[id] ?? nil) != nil, "\(id) 应生成封面")
        }
        // 同一来源的缩略图应一致（用于判断没有互相覆盖）
        let tallA = try #require(results[ids[0]] ?? nil)
        let tallB = try #require(results[ids[10]] ?? nil)
        #expect(tallA == tallB)
    }

    @Test("并发取同一作品：结果一致且只产生一个文件")
    func concurrentSameMangaIsConsistent() async throws {
        let (cache, root) = try makeCache()
        defer { TestFileSystem.remove(root) }

        let mangaID = "local|LocalLibrary/same.cbz"
        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 {
                group.addTask { cache.thumbnail(mangaID: mangaID) { Self.tallPNG } }
            }
            var all: [Data?] = []
            for await data in group { all.append(data) }
            return all
        }

        let first = try #require(results.first ?? nil)
        for data in results { #expect(data == first) }

        let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(files.count == 1, "同一作品只应有一个缓存文件")
    }
}
