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

    private func directory(for jobID: String) throws -> URL {
        guard !jobID.isEmpty, !jobID.contains("/"), !jobID.contains("\\"), !jobID.contains("..") else {
            throw AppError.invalidInput("任务标识不合法：\(jobID)")
        }
        return rootDirectory.appendingPathComponent(jobID, isDirectory: true)
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
}
