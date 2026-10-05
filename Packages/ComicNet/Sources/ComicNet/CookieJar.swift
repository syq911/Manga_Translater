//
//  CookieJar.swift
//  ComicNet
//
//  按来源隔离的 Cookie 存储。
//
//  为什么必须按来源隔离：不同来源可能使用同名 Cookie（如 `session`），
//  混在一起会把 A 站的登录态发给 B 站——既是隐私问题，也会导致登录失败。
//
//  持久化：整个 jar 序列化为 JSON 落盘；文件损坏时自动备份并重置，
//  绝不因为一份坏文件导致 App 无法启动。
//

import Foundation
import AppCore

/// 一条 Cookie。
public struct StoredCookie: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    /// 归属域名（不含 scheme）。空串表示「该来源下所有域名通用」。
    public var domain: String
    /// 生效路径前缀。
    public var path: String
    /// 过期时间。nil 表示会话级（不落盘、关 App 即失效）。
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String = "",
        path: String = "/",
        expiresAt: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    /// 是否已过期。
    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// 该 Cookie 是否适用于给定 host。
    public func matches(host: String) -> Bool {
        guard !domain.isEmpty else { return true }
        let normalizedHost = host.lowercased()
        let normalizedDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
    }

    /// 该 Cookie 是否适用于给定路径。
    public func matches(path requestPath: String) -> Bool {
        if path.isEmpty || path == "/" { return true }
        return requestPath.hasPrefix(path)
    }
}

/// 按来源隔离的 Cookie 存储。
public final class CookieJar: @unchecked Sendable {

    private var storage: [String: [StoredCookie]] = [:]
    private let lock = NSLock()
    private let storageURL: URL?
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - storageURL: 持久化文件地址。nil 表示纯内存（测试与临时会话用）。
    ///   - clock: 时间源。
    public init(storageURL: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.storageURL = storageURL
        self.clock = clock
        if let storageURL {
            loadFromDisk(at: storageURL)
        }
    }

    // MARK: 写入

    /// 写入 / 覆盖一条 Cookie。同名同域同路径视为同一条。
    /// - Throws: `AppError.invalidInput`——名称为空或含非法字符。
    public func set(_ cookie: StoredCookie, for sourceID: SourceID) throws {
        let name = cookie.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AppError.invalidInput("Cookie 名称不能为空")
        }
        guard !name.contains(";"), !name.contains("="), !name.contains("\n") else {
            throw AppError.invalidInput("Cookie 名称含非法字符：\(name)")
        }
        guard !cookie.value.contains("\n") else {
            throw AppError.invalidInput("Cookie 值含换行符")
        }

        var normalized = cookie
        normalized.name = name

        lock.lock()
        defer { lock.unlock() }
        var bucket = storage[sourceID.rawValue] ?? []
        if let index = bucket.firstIndex(where: {
            $0.name == normalized.name && $0.domain == normalized.domain && $0.path == normalized.path
        }) {
            bucket[index] = normalized
        } else {
            bucket.append(normalized)
        }
        storage[sourceID.rawValue] = bucket
    }

    /// 批量写入（用于从网页登录收割 Cookie）。
    /// 任何一条非法都不会中断其余写入，返回被拒绝的条目数。
    @discardableResult
    public func set(_ cookies: [StoredCookie], for sourceID: SourceID) -> Int {
        var rejected = 0
        for cookie in cookies {
            do {
                try set(cookie, for: sourceID)
            } catch {
                rejected += 1
            }
        }
        return rejected
    }

    // MARK: 读取

    /// 读取某个来源的 Cookie。默认过滤已过期项。
    public func cookies(
        for sourceID: SourceID,
        host: String? = nil,
        path: String? = nil,
        includeExpired: Bool = false,
        secureOnly: Bool = false
    ) -> [StoredCookie] {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        let bucket = storage[sourceID.rawValue] ?? []
        return bucket.filter { cookie in
            if !includeExpired, cookie.isExpired(at: now) { return false }
            if secureOnly, !cookie.isSecure { return false }
            if let host, !cookie.matches(host: host) { return false }
            if let path, !cookie.matches(path: path) { return false }
            return true
        }
    }

    /// 构造请求头用的 Cookie 串（`a=b; c=d`）。无可用 Cookie 时返回 nil。
    public func cookieHeader(for sourceID: SourceID, url: String) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host else { return nil }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        let items = cookies(for: sourceID, host: host, path: path)
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 某个来源是否有可用（未过期）Cookie。
    public func hasCookies(for sourceID: SourceID) -> Bool {
        !cookies(for: sourceID).isEmpty
    }

    /// 删除单条。
    @discardableResult
    public func remove(name: String, for sourceID: SourceID, domain: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var bucket = storage[sourceID.rawValue] else { return false }
        let before = bucket.count
        bucket.removeAll { cookie in
            guard cookie.name == name else { return false }
            if let domain { return cookie.domain == domain }
            return true
        }
        let removed = before != bucket.count
        if bucket.isEmpty {
            storage.removeValue(forKey: sourceID.rawValue)
        } else {
            storage[sourceID.rawValue] = bucket
        }
        return removed
    }

    // MARK: 清理

    /// 清空某个来源的 Cookie（登出、切换账号时使用）。
    public func clear(sourceID: SourceID) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: sourceID.rawValue)
    }

    /// 清空全部（退出登录 / 重置 App）。
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// 清理所有已过期 Cookie，返回清理条数。
    @discardableResult
    public func pruneExpired(at date: Date? = nil) -> Int {
        let now = date ?? clock()
        lock.lock()
        defer { lock.unlock() }
        var removed = 0
        for (key, bucket) in storage {
            let survivors = bucket.filter { !$0.isExpired(at: now) }
            removed += bucket.count - survivors.count
            if survivors.isEmpty {
                storage.removeValue(forKey: key)
            } else {
                storage[key] = survivors
            }
        }
        return removed
    }

    // MARK: 持久化

    /// 落盘（原子写：先写临时文件再替换，避免中途崩溃留下半个文件）。
    /// - Throws: `AppError.fileSystem`。
    public func persist() throws {
        guard let storageURL else { return }
        let snapshot: [String: [StoredCookie]]
        lock.lock()
        snapshot = storage
        lock.unlock()

        do {
            let directory = storageURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw AppError.normalize(error)
        }
    }

    /// 从磁盘加载。文件不存在 → 空；文件损坏 → 备份为 `.corrupt` 并重置（不抛错）。
    public func loadFromDisk(at url: URL? = nil) {
        guard let target = url ?? storageURL else { return }
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            let data = try Data(contentsOf: target)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([String: [StoredCookie]].self, from: data)
            lock.lock()
            storage = decoded
            lock.unlock()
        } catch {
            let backup = target.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: target, to: backup)
            lock.lock()
            storage = [:]
            lock.unlock()
            diag("CookieJar: 存储文件损坏，已备份为 \(backup.lastPathComponent)")
        }
    }

    /// 当前条目总数（测试与设置页展示用）。
    public var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.reduce(0) { $0 + $1.count }
    }

    /// 已记录 Cookie 的来源数量。
    public var sourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
