//
//  DownloadArchiveStore.swift
//  ComicDownload
//
//  下载归档：把「已下载完的一章」打成 CBZ 落到磁盘，并支持读回单页。
//
//  为什么下完就打包成 CBZ，而不是留着一堆散图：
//  1. **离线阅读只需要一条代码路径**——CBZ 与用户自己导入的本地漫画是同一种东西，
//     阅读器、封面、章节排序全都不用为「下载的」再写一套；
//  2. 散图目录的「这一章下完了没有」只能用「文件数 == 页数」猜，而打包是**原子**的：
//     文件在 = 完整，文件不在 = 没下完，不存在中间态；
//  3. 用户要导出时不必再打一次包。
//
//  目录布局（`<root>/<manga 目录>/<chapter 文件>`）：
//
//      <root>/Demo_A1b2c3d4/Demo__Chapter_1_a1b2c3d4.cbz
//      <root>/Demo_A1b2c3d4/Demo__Chapter_1_a1b2c3d4.json   ← 清单（元数据）
//
//  文件名是「可读部分 + 稳定哈希」：主键形如 `<sourceID>|<url>`，含 `/`、`:`、`|`
//  等不能进文件名的字符；只做可读化会撞名，只做哈希则无法人工排查。
//  哈希用 FNV-1a（自实现，不依赖具体运行时的 `hashValue`——那个**跨进程不稳定**，
//  用它命名会导致下次启动找不到自己写的文件）。
//

import Foundation
import AppCore

/// 已归档的一章。
public struct DownloadedChapter: Equatable, Sendable, Codable, Identifiable {
    public let mangaID: String
    /// 作品标题（可选：清单是 M3 才加的字段，老清单里没有）。
    public var mangaTitle: String?
    public let chapterID: String
    public var chapterName: String
    /// 归档时的页数（用于「整章下完」的判定与进度显示）。
    public let pageCount: Int
    /// CBZ 文件字节数。
    public let byteCount: Int
    public let archivedAt: Date

    public var id: String { chapterID }

    public init(
        mangaID: String,
        mangaTitle: String? = nil,
        chapterID: String,
        chapterName: String,
        pageCount: Int,
        byteCount: Int,
        archivedAt: Date
    ) {
        self.mangaID = mangaID
        self.mangaTitle = mangaTitle
        self.chapterID = chapterID
        self.chapterName = chapterName
        self.pageCount = pageCount
        self.byteCount = byteCount
        self.archivedAt = archivedAt
    }
}

/// 归档存储。
///
/// 线程安全（内部串行队列）：下载在后台线程收尾、阅读在主线程读图，
/// 两边会同时碰到同一批文件。
public final class DownloadArchiveStore: @unchecked Sendable {

    private let rootDirectory: URL
    private let exporter: CbzExporter
    private let fileManager: FileManager

    public init(
        rootDirectory: URL,
        exporter: CbzExporter = CbzExporter(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.exporter = exporter
        self.fileManager = fileManager
    }

    // MARK: 命名

    /// 把任意主键转成「可读 + 唯一」的文件名片段（见 `FileNameSanitizer`）。
    public static func fileNameSegment(_ raw: String) -> String {
        FileNameSanitizer.segment(raw)
    }

    /// FNV-1a 稳定哈希（见 `FileNameSanitizer`）。
    public static func stableHash(_ text: String) -> String {
        FileNameSanitizer.stableHash(text)
    }

    private func directory(forManga mangaID: String) -> URL {
        rootDirectory.appendingPathComponent(Self.fileNameSegment(mangaID), isDirectory: true)
    }

    private func fileURLs(mangaID: String, chapterID: String) -> (archive: URL, manifest: URL) {
        let stem = Self.fileNameSegment(chapterID)
        let directory = directory(forManga: mangaID)
        return (
            directory.appendingPathComponent("\(stem).cbz", isDirectory: false),
            directory.appendingPathComponent("\(stem).json", isDirectory: false)
        )
    }

    /// 已归档章节的 CBZ 路径（不保证存在）。
    public func archiveURL(mangaID: String, chapterID: String) -> URL {
        fileURLs(mangaID: mangaID, chapterID: chapterID).archive
    }

    // MARK: 写入

    /// 把一章的页打包成 CBZ 落盘。
    ///
    /// 先写临时文件再 `replaceItemAt`：直接覆盖时若中途失败，
    /// 磁盘上会留下一个**打不开的 CBZ**，而它看起来「已下载完成」。
    @discardableResult
    public func archive(
        pages: [CbzPage],
        mangaID: String,
        chapterID: String,
        chapterName: String,
        mangaTitle: String? = nil,
        date: Date = Date()
    ) throws -> DownloadedChapter {
        guard !pages.isEmpty else { throw CbzExportError.noPages }

        let urls = fileURLs(mangaID: mangaID, chapterID: chapterID)
        let directory = urls.archive.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try exporter.export(pages: pages, title: chapterName, date: date)
        let temporary = directory.appendingPathComponent(
            ".\(urls.archive.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: urls.archive.path) {
                _ = try fileManager.replaceItemAt(urls.archive, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: urls.archive)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw AppError.normalize(error)
        }

        let record = DownloadedChapter(
            mangaID: mangaID,
            mangaTitle: mangaTitle,
            chapterID: chapterID,
            chapterName: chapterName,
            pageCount: pages.count,
            byteCount: data.count,
            archivedAt: date
        )
        if let manifest = try? JSONEncoder().encode(record) {
            try? manifest.write(to: urls.manifest, options: .atomic)
        }
        return record
    }

    // MARK: 查询

    /// 某一章是否已归档。
    public func hasChapter(mangaID: String, chapterID: String) -> Bool {
        fileManager.fileExists(atPath: archiveURL(mangaID: mangaID, chapterID: chapterID).path)
    }

    /// 读取某一章的清单。
    public func chapter(mangaID: String, chapterID: String) -> DownloadedChapter? {
        let urls = fileURLs(mangaID: mangaID, chapterID: chapterID)
        guard let data = try? Data(contentsOf: urls.manifest),
              let record = try? JSONDecoder().decode(DownloadedChapter.self, from: data)
        else { return nil }
        return record
    }

    /// 某作品已归档的章节（按清单文件名稳定排序；调用方可自行按章节序排）。
    public func chapters(mangaID: String) -> [DownloadedChapter] {
        records(inDirectory: directory(forManga: mangaID))
    }

    /// 所有已归档章节（按作品目录名、清单文件名稳定排序）。
    public func allChapters() -> [DownloadedChapter] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { records(inDirectory: $0) }
    }

    /// 读一个作品目录下的全部清单（按文件名排序）。
    private func records(inDirectory directory: URL) -> [DownloadedChapter] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name in
                let url = directory.appendingPathComponent(name, isDirectory: false)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(DownloadedChapter.self, from: data)
            }
    }

    /// 归档占用的总字节数。
    public func totalBytes() -> Int {
        allChapters().reduce(0) { $0 + $1.byteCount }
    }

    // MARK: 读页

    /// 从归档里读出第 `pageIndex`（0 起）页。
    /// 归档不存在或页号越界返回 nil，调用方据此回落到网络。
    public func pageData(mangaID: String, chapterID: String, pageIndex: Int) -> Data? {
        guard pageIndex >= 0 else { return nil }
        let url = archiveURL(mangaID: mangaID, chapterID: chapterID)
        guard let data = try? Data(contentsOf: url),
              let reader = try? ZipArchiveReader(data: data)
        else { return nil }
        return Self.pageData(in: reader, pageIndex: pageIndex)
    }

    /// 归档里的页数（用于「文件在但清单丢了」时的兜底）。
    public func pageCount(mangaID: String, chapterID: String) -> Int? {
        let url = archiveURL(mangaID: mangaID, chapterID: chapterID)
        guard let data = try? Data(contentsOf: url),
              let reader = try? ZipArchiveReader(data: data)
        else { return nil }
        return Self.pageNames(in: reader).count
    }

    /// 归档里的页条目名（已过滤清单文件并按页序排好）。
    ///
    /// 不假设扩展名一定是 `jpg`：图床给 webp/png 时原来的
    /// `defaultPageName(index:)`（固定 `.jpg`）会查不到。
    static func pageNames(in reader: ZipArchiveReader) -> [String] {
        reader.entryNames
            .filter { !$0.hasSuffix("/") && $0.lowercased() != "comicinfo.txt" }
            .filter { name in
                guard let dot = name.lastIndex(of: ".") else { return false }
                let ext = name[name.index(after: dot)...].lowercased()
                return CbzExporter.allowedExtensions.contains(ext)
            }
            .sorted()
    }

    static func pageData(in reader: ZipArchiveReader, pageIndex: Int) -> Data? {
        let names = pageNames(in: reader)
        guard pageIndex < names.count else { return nil }
        return try? reader.data(for: names[pageIndex])
    }

    // MARK: 删除

    /// 删除某章归档。
    @discardableResult
    public func removeChapter(mangaID: String, chapterID: String) -> Bool {
        let urls = fileURLs(mangaID: mangaID, chapterID: chapterID)
        var removed = false
        for url in [urls.archive, urls.manifest] where fileManager.fileExists(atPath: url.path) {
            if (try? fileManager.removeItem(at: url)) != nil { removed = true }
        }
        // 目录空了就删掉，避免留下空壳目录
        let directory = urls.archive.deletingLastPathComponent()
        if let rest = try? fileManager.contentsOfDirectory(atPath: directory.path), rest.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
        return removed
    }

    /// 删除某作品的全部归档。返回删除的章节数。
    @discardableResult
    public func removeManga(mangaID: String) -> Int {
        let count = chapters(mangaID: mangaID).count
        let directory = directory(forManga: mangaID)
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        return count
    }

    /// 清空全部归档。返回清掉的章节数。
    @discardableResult
    public func removeAll() -> Int {
        let count = allChapters().count
        if fileManager.fileExists(atPath: rootDirectory.path) {
            try? fileManager.removeItem(at: rootDirectory)
        }
        return count
    }
}
