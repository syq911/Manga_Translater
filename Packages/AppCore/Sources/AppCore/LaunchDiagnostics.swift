//
//  LaunchDiagnostics.swift
//  AppCore
//
//  轻量诊断日志。随时可写（Release 也生效），用于排查
//  「识别不到文字 / 漏行 / 翻译失败 / 源不可用」等问题。
//
//  设计要点：
//  - 目录可注入，测试写临时目录，不污染用户文档目录。
//  - 线程安全（多任务并发写）。
//  - 超过 `maxBytes` 自动轮转为 `<file>.1`（只保留一份历史），避免无限增长。
//  - 读取 / 清理接口供「设置 → 导出诊断日志」使用。
//

import Foundation

/// 诊断日志写入器。
public final class DiagnosticsLog: @unchecked Sendable {

    /// 全局共享实例（App 与各模块统一使用）。
    public static let shared = DiagnosticsLog()

    public let fileURL: URL

    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var handle: FileHandle?

    /// - Parameters:
    ///   - directory: 日志目录。nil 表示使用「文档目录」。
    ///   - fileName: 日志文件名。
    ///   - maxBytes: 单文件上限，超过即轮转。
    ///   - now: 时间源（测试可注入）。
    public init(
        directory: URL? = nil,
        fileName: String = "MangaTranslaterDiagnostics.log",
        maxBytes: Int = 512 * 1024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let base = directory ?? DiagnosticsLog.defaultDirectory()
        self.fileURL = base.appendingPathComponent(fileName, isDirectory: false)
        self.maxBytes = max(1024, maxBytes)
        self.now = now
    }

    deinit {
        handle?.closeFile()
    }

    /// 默认目录：文档目录（App 开启文件共享后可在「文件」App 中取出）。
    public static func defaultDirectory() -> URL {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    /// 写入一条日志。空消息被忽略（避免产生无意义空行）。
    public func log(_ message: String) {
        log(message, at: now())
    }

    /// 写入一条带指定时间的日志。
    public func log(_ message: String, at date: Date) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = "[\(DiagnosticsLog.formatter.string(from: date))] \(trimmed)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            try rotateIfNeeded(additionalBytes: data.count)
            let handle = try resolvedHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 诊断日志自身绝不能影响主流程：写失败就静默放弃。
            handle = nil
        }
    }

    /// 读取全部日志内容（文件不存在返回空串）。
    public func readAll() -> String {
        lock.lock()
        defer { lock.unlock() }
        handle?.synchronizeFile()
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 清空日志（同时删除轮转文件）。
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        handle?.closeFile()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: rotatedFileURL)
    }

    /// 当前日志字节数。
    public var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? Int) ?? 0
    }

    /// 轮转文件地址。
    public var rotatedFileURL: URL {
        fileURL.appendingPathExtension("1")
    }

    // MARK: 内部

    private func resolvedHandle() throws -> FileHandle {
        if let handle { return handle }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let created = try? FileHandle(forWritingTo: fileURL) else {
            throw AppError.fileSystem(Copy.format("error.app.logOpenFailed", fileURL.lastPathComponent))
        }
        handle = created
        return created
    }

    private func rotateIfNeeded(additionalBytes: Int) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let current = (attributes?[.size] as? Int) ?? 0
        guard current + additionalBytes > maxBytes else { return }

        handle?.closeFile()
        handle = nil
        try? FileManager.default.removeItem(at: rotatedFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedFileURL)
    }
}

/// 全局诊断打点函数。
///
/// 用法：`diag("SourceEngine: 安装了源 \(id)，大小 \(bytes) 字节")`
public func diag(_ message: String) {
    DiagnosticsLog.shared.log(message)
}
