//
//  DownloadTransport.swift
//  ComicDownload
//
//  下载所需的两个抽象：取页数据、落盘存储。
//  抽出来的目的：单元测试可以完全离线运行，并且能注入失败以验证回滚。
//

import Foundation
import AppCore

/// 单页抓取。
public protocol PageFetching: Sendable {
    /// 抓取一页图片数据。
    /// - Throws: 任意错误都会被队列记录并按重试策略处理。
    func fetchPage(url: String, headers: [String: String]) async throws -> Data
}

/// 需要「按任务区分来源」的抓取器实现这个。
///
/// 动机：登录态（Cookie）与防盗链 `Referer` 都是**来源侧**的知识，
/// 而队列只有一个 `fetcher`，它不该知道来源。让抓取器从任务上读即可——
/// 于是一个实例就能服务队列里多个来源的任务。
public protocol JobAwarePageFetching: PageFetching {
    func fetchPage(url: String, headers: [String: String], job: DownloadJob) async throws -> Data
}

/// 页数据落盘。
public protocol PageStoring: Sendable {
    /// 为任务准备目录；已存在时应清空（避免上次残留混入）。
    func prepare(jobID: String) throws
    /// 写入第 `index` 页。
    func store(data: Data, jobID: String, index: Int) throws
    /// 已落盘页数。
    func storedPageCount(jobID: String) -> Int
    /// 清理任务的全部数据（失败 / 取消时回滚）。
    func cleanup(jobID: String) throws
}

/// 内存实现（测试用）。
public final class InMemoryPageStore: PageStoring, @unchecked Sendable {
    private var storage: [String: [Int: Data]] = [:]
    private let lock = NSLock()

    public init() {}

    public func prepare(jobID: String) throws {
        lock.lock()
        storage[jobID] = [:]
        lock.unlock()
    }

    public func store(data: Data, jobID: String, index: Int) throws {
        lock.lock()
        storage[jobID, default: [:]][index] = data
        lock.unlock()
    }

    public func storedPageCount(jobID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage[jobID]?.count ?? 0
    }

    public func cleanup(jobID: String) throws {
        lock.lock()
        storage.removeValue(forKey: jobID)
        lock.unlock()
    }

    /// 某个任务的页数据（按索引升序）。
    public func pages(jobID: String) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = storage[jobID] else { return [] }
        return bucket.keys.sorted().compactMap { bucket[$0] }
    }
}

/// 基于文件系统的实现：`<root>/<jobID>/0001.jpg` 形式落盘。
public final class FilePageStore: PageStoring, @unchecked Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// 任务目录。
    ///
    /// 早期实现是「拒绝含 `/` 的 jobID」，但本项目的章节主键形如
    /// `<mangaID>|<url>`，**必然含 `/`**（URL 就在里面），
    /// 于是所有在线章节的下载都会在第一步就报「任务标识不合法」。
    /// 正确做法是把标识**安全化**成文件名片段（同时消除路径穿越的可能）。
    private func directory(for jobID: String) throws -> URL {
        guard !jobID.isEmpty else {
            throw AppError.invalidInput(Copy.text("error.download.emptyJobID"))
        }
        return rootDirectory.appendingPathComponent(
            FileNameSanitizer.segment(jobID),
            isDirectory: true
        )
    }

    public func prepare(jobID: String) throws {
        let directory = try directory(for: jobID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func store(data: Data, jobID: String, index: Int) throws {
        let directory = try directory(for: jobID)
        let url = directory.appendingPathComponent(CbzExporter.defaultPageName(index: index), isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    public func storedPageCount(jobID: String) -> Int {
        guard let directory = try? directory(for: jobID),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        return files.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") || $0.hasSuffix(".webp") }.count
    }

    public func cleanup(jobID: String) throws {
        let directory = try directory(for: jobID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 已落盘的页，按页序返回（供下载完成后打包归档）。
    ///
    /// 页序取自**文件名里的数字前缀**而不是目录顺序：
    /// `contentsOfDirectory` 的顺序不保证（实测不同文件系统上不一致），
    /// 按它排序会得到「第 10 页排在第 2 页前面」这种结果。
    public func pages(jobID: String) -> [CbzPage] {
        guard let directory = try? directory(for: jobID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            return []
        }
        return names
            .compactMap { name -> (Int, String, String)? in
                guard let dot = name.lastIndex(of: ".") else { return nil }
                let stem = String(name[name.startIndex..<dot])
                let ext = String(name[name.index(after: dot)...]).lowercased()
                guard let index = Int(stem), CbzExporter.allowedExtensions.contains(ext) else {
                    return nil
                }
                // 文件名是 1 起的（`0001.jpg`），模型里是 0 起
                return (index - 1, name, ext)
            }
            .sorted { $0.0 < $1.0 }
            .compactMap { index, name, ext -> CbzPage? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                    return nil
                }
                return CbzPage(index: index, data: data, fileExtension: ext)
            }
    }
}
