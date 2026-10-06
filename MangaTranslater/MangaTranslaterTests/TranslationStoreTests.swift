//
//  TranslationStoreTests.swift
//  MangaTranslaterTests
//
//  译文缓存：内存命中、磁盘持久化、LRU 淘汰、按作品清理、损坏文件容错。
//
//  全部落临时目录，用例之间不共享状态。
//

import Foundation
import Testing
import CoreGraphics
import UIKit
import AppCore
@testable import MangaTranslater

@Suite("译文缓存")
struct TranslationStoreTests {

    private static func makeImage(size: CGFloat = 8) -> UIImage {
        let width = Int(size)
        let height = Int(size)
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context?.makeImage() else { return UIImage() }
        return UIImage(cgImage: cgImage)
    }

    private static func line(_ text: String) -> MangaTranslatedLine {
        MangaTranslatedLine(
            source: text,
            translated: "译:\(text)",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            isVertical: false
        )
    }

    private static func key(page: Int, manga: String = "https://example.com/m/1") -> PageTranslationKey {
        PageTranslationKey(sourceID: SourceID("demo"), mangaURL: manga, page: page)
    }

    // MARK: 键

    @Test func keyStemIsPathSafe() {
        let value = PageTranslationKey(
            sourceID: SourceID("demo"),
            mangaURL: "https://example.com/a/b/c?q=1",
            page: 3
        )
        #expect(!value.mangaStem.contains("/"))
        #expect(!value.mangaStem.contains(":"))
        #expect(!value.mangaStem.contains("?"))
        #expect(value.pageFileName == "3")
        #expect(value.description.contains("https://example.com/a/b/c?q=1"))
    }

    @Test func keyClampsNegativePage() {
        let value = PageTranslationKey(sourceID: SourceID("demo"), mangaURL: "u", page: -5)
        #expect(value.page == 0)
    }

    @Test func keysDifferAcrossMangaAndSource() {
        let a = PageTranslationKey(sourceID: SourceID("a"), mangaURL: "u", page: 1)
        let b = PageTranslationKey(sourceID: SourceID("b"), mangaURL: "u", page: 1)
        let c = PageTranslationKey(sourceID: SourceID("a"), mangaURL: "u", page: 2)
        #expect(a != b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 3)
    }

    // MARK: 内存

    @Test func memoryRoundTrip() throws {
        let store = TranslationStore(root: nil)
        let key = Self.key(page: 0)
        store.store(image: Self.makeImage(), lines: [Self.line("a")], for: key)

        let entry = try #require(store.entry(for: key))
        #expect(entry.lines.count == 1)
        #expect(entry.lines.first?.translated == "译:a")
        #expect(store.contains(key))
        #expect(store.memoryCount == 1)
    }

    @Test func missReturnsNil() {
        let store = TranslationStore(root: nil)
        #expect(store.entry(for: Self.key(page: 9)) == nil)
        #expect(store.image(for: Self.key(page: 9)) == nil)
        #expect(!store.contains(Self.key(page: 9)))
    }

    @Test func memoryIsEvictedButDiskSurvives() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = TranslationStore(root: root, memoryLimit: 2)
        for page in 0..<3 {
            store.store(image: Self.makeImage(), lines: [Self.line("p\(page)")], for: Self.key(page: page))
        }
        #expect(store.memoryCount == 2)
        // 第 0 页被挤出内存，但磁盘仍在 → 仍能读到
        let revived = try #require(store.entry(for: Self.key(page: 0)))
        #expect(revived.lines.first?.source == "p0")
    }

    // MARK: 磁盘

    @Test func diskPersistsAcrossInstances() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let first = TranslationStore(root: root)
        first.store(image: Self.makeImage(), lines: [Self.line("x")], for: Self.key(page: 4))

        // 全新实例：内存为空，必须靠磁盘命中
        let second = TranslationStore(root: root)
        #expect(second.memoryCount == 0)
        let entry = try #require(second.entry(for: Self.key(page: 4)))
        #expect(entry.lines.first?.translated == "译:x")
        #expect(second.diskUsageBytes() > 0)
    }

    @Test func corruptImageFileIsTreatedAsMiss() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let key = Self.key(page: 0)
        let directory = root.appendingPathComponent(key.mangaStem, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a png".utf8).write(to: directory.appendingPathComponent("0.png"))

        let store = TranslationStore(root: root)
        #expect(store.contains(key))          // 文件在
        #expect(store.entry(for: key) == nil) // 但解不出图 → 视为未缓存
    }

    @Test func missingMetadataStillYieldsImage() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let key = Self.key(page: 0)
        let directory = root.appendingPathComponent(key.mangaStem, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try #require(Self.makeImage().pngData())
        try png.write(to: directory.appendingPathComponent("0.png"))

        let store = TranslationStore(root: root)
        let entry = try #require(store.entry(for: key))
        #expect(entry.lines.isEmpty)
    }

    // MARK: 清理

    @Test func removeAllClearsMemoryAndDisk() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = TranslationStore(root: root)
        store.store(image: Self.makeImage(), lines: [Self.line("a")], for: Self.key(page: 0))
        store.store(image: Self.makeImage(), lines: [Self.line("b")], for: Self.key(page: 1))
        #expect(store.diskUsageBytes() > 0)

        let removed = store.removeAll()
        #expect(removed == 2)
        #expect(store.memoryCount == 0)
        #expect(store.diskUsageBytes() == 0)
        #expect(store.entry(for: Self.key(page: 0)) == nil)
    }

    @Test func removeAllRemovesOnlyTargetManga() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = TranslationStore(root: root)
        let target = Self.key(page: 0, manga: "https://example.com/m/1")
        let other = Self.key(page: 0, manga: "https://example.com/m/2")
        store.store(image: Self.makeImage(), lines: [Self.line("keep")], for: other)
        store.store(image: Self.makeImage(), lines: [Self.line("drop")], for: target)

        store.removeAll(sourceID: target.sourceID, mangaURL: target.mangaURL)

        #expect(store.entry(for: target) == nil)
        let survivor = try #require(store.entry(for: other))
        #expect(survivor.lines.first?.source == "keep")
        // 另一个作品的目录仍在磁盘上
        let otherDirectory = root.appendingPathComponent(other.mangaStem, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: otherDirectory.path))
    }

    @Test func removeAllOnMissingRootIsHarmless() {
        let store = TranslationStore(root: nil)
        #expect(store.removeAll() == 0)
        #expect(store.diskUsageBytes() == 0)
        store.removeAll(sourceID: SourceID("demo"), mangaURL: "u")
        #expect(store.memoryCount == 0)
    }

    // MARK: 覆盖写

    @Test func storingAgainReplacesValue() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = TranslationStore(root: root)
        let key = Self.key(page: 0)
        store.store(image: Self.makeImage(), lines: [Self.line("old")], for: key)
        store.store(image: Self.makeImage(), lines: [Self.line("new")], for: key)

        let entry = try #require(store.entry(for: key))
        #expect(entry.lines.first?.source == "new")

        // 重开一个实例，确认磁盘上也是新值（而不是旧值残留）
        let second = TranslationStore(root: root)
        let persisted = try #require(second.entry(for: key))
        #expect(persisted.lines.first?.source == "new")
    }
}
