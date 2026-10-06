//
//  TranslationStore.swift
//  MangaTranslater
//
//  译文缓存：内存（LRU）+ 磁盘（按作品分目录）。
//
//  为什么两级：
//  - **内存**是为了翻页流畅——往回翻一页要立刻出图，不能等磁盘 IO；
//  - **磁盘**是为了「翻译一次、长期有效」——同一话重看时不必再花额度
//    （云服务按页计费，重复翻译就是重复花钱）。
//
//  为什么键是「作品 + 页号」而不是页图哈希：译文图是**在原图之上重绘**的产物，
//  与原图字节一一对应；但同一页在不同来源下可能字节不同（压缩参数不同），
//  用来源 + 作品地址 + 页号既能命中缓存，也不会把不同来源的页混在一起。
//
//  写盘策略：先写临时文件再原子替换（`Data.write(options: .atomic)`），
//  避免「写了一半被杀进程」留下半张图，被当成有效缓存读出来。
//
//  所有磁盘错误都吞掉并只记诊断日志：缓存失败不该让阅读功能失败。
//

import Foundation
import UIKit
import AppCore

final class TranslationStore: @unchecked Sendable {

    /// 一条缓存记录。
    struct Entry {
        let image: UIImage
        let lines: [MangaTranslatedLine]
    }

    /// 磁盘根目录。`nil` 表示纯内存（测试 / 磁盘不可用时的降级）。
    private let root: URL?
    /// 内存里保留的最大页数。
    private let memoryLimit: Int

    private let lock = NSLock()
    private var memory: [PageTranslationKey: Entry] = [:]
    /// 最近使用顺序（末尾最新）。
    private var recency: [PageTranslationKey] = []

    init(root: URL?, memoryLimit: Int = 48) {
        self.root = root
        self.memoryLimit = max(1, memoryLimit)
    }

    // MARK: 读

    func entry(for key: PageTranslationKey) -> Entry? {
        lock.lock()
        if let cached = memory[key] {
            touch(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let loaded = loadFromDisk(key) else { return nil }
        lock.lock()
        insert(loaded, for: key)
        lock.unlock()
        return loaded
    }

    func image(for key: PageTranslationKey) -> UIImage? {
        entry(for: key)?.image
    }

    func lines(for key: PageTranslationKey) -> [MangaTranslatedLine]? {
        entry(for: key)?.lines
    }

    /// 内存或磁盘里是否已有这一页（不触发放大读取）。
    func contains(_ key: PageTranslationKey) -> Bool {
        lock.lock()
        if memory[key] != nil {
            lock.unlock()
            return true
        }
        lock.unlock()
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: imageURL(key, root: root).path)
    }

    /// 已有缓存的作品 URL 集合（设置页「清理译文缓存」用不上，留给诊断面板）。
    var memoryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return memory.count
    }

    // MARK: 写

    func store(image: UIImage, lines: [MangaTranslatedLine], for key: PageTranslationKey) {
        let entry = Entry(image: image, lines: lines)
        lock.lock()
        insert(entry, for: key)
        lock.unlock()
        writeToDisk(entry, for: key)
    }

    // MARK: 清理

    /// 清空全部译文缓存（内存 + 磁盘）。
    @discardableResult
    func removeAll() -> Int {
        lock.lock()
        let count = memory.count
        memory.removeAll()
        recency.removeAll()
        lock.unlock()

        guard let root, FileManager.default.fileExists(atPath: root.path) else {
            return count
        }
        let removed = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in removed {
            try? FileManager.default.removeItem(at: url)
        }
        diag("翻译缓存: 已清空（内存 \(count) 页，磁盘目录 \(root.lastPathComponent)）")
        return count
    }

    /// 清掉某个作品的全部译文（内存 + 磁盘）。
    func removeAll(sourceID: SourceID, mangaURL: String) {
        let stem = PageTranslationKey(sourceID: sourceID, mangaURL: mangaURL, page: 0).mangaStem
        lock.lock()
        let keys = memory.keys.filter { $0.sourceID == sourceID && $0.mangaURL == mangaURL }
        for key in keys {
            memory[key] = nil
            recency.removeAll { $0 == key }
        }
        lock.unlock()

        guard let root else { return }
        let directory = root.appendingPathComponent(stem, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 磁盘占用（字节）。
    func diskUsageBytes() -> Int {
        guard let root, FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        var total = 0
        while let url = enumerator?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }

    // MARK: 内存

    private func touch(_ key: PageTranslationKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func insert(_ entry: Entry, for key: PageTranslationKey) {
        memory[key] = entry
        touch(key)
        while recency.count > memoryLimit, let oldest = recency.first {
            recency.removeFirst()
            memory[oldest] = nil
        }
    }

    // MARK: 磁盘

    private func imageURL(_ key: PageTranslationKey, root: URL) -> URL {
        root
            .appendingPathComponent(key.mangaStem, isDirectory: true)
            .appendingPathComponent(key.pageFileName + ".png", isDirectory: false)
    }

    private func linesURL(_ key: PageTranslationKey, root: URL) -> URL {
        root
            .appendingPathComponent(key.mangaStem, isDirectory: true)
            .appendingPathComponent(key.pageFileName + ".json", isDirectory: false)
    }

    private func loadFromDisk(_ key: PageTranslationKey) -> Entry? {
        guard let root else { return nil }
        guard let data = try? Data(contentsOf: imageURL(key, root: root)),
              let image = UIImage(data: data) else { return nil }
        var lines: [MangaTranslatedLine] = []
        if let metaData = try? Data(contentsOf: linesURL(key, root: root)),
           let decoded = try? JSONDecoder().decode([MangaTranslatedLine].self, from: metaData) {
            lines = decoded
        }
        return Entry(image: image, lines: lines)
    }

    private func writeToDisk(_ entry: Entry, for key: PageTranslationKey) {
        guard let root else { return }
        let directory = root.appendingPathComponent(key.mangaStem, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            diag("翻译缓存: 无法创建目录 —— \(error.localizedDescription)")
            return
        }
        if let png = entry.image.pngData() {
            do {
                try png.write(to: imageURL(key, root: root), options: .atomic)
            } catch {
                diag("翻译缓存: 写图失败 —— \(error.localizedDescription)")
            }
        }
        if let meta = try? JSONEncoder().encode(entry.lines) {
            do {
                try meta.write(to: linesURL(key, root: root), options: .atomic)
            } catch {
                diag("翻译缓存: 写清单失败 —— \(error.localizedDescription)")
            }
        }
    }
}
