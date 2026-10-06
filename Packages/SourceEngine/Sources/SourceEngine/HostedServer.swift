//
//  HostedServer.swift
//  SourceEngine
//
//  自建服务器（Komga / Kavita）的连接配置与存储。
//
//  为什么自建服务器是「内置集成」而不是「脚本源」：
//  它是**用户自己的服务器**（自己的漫画库），不是第三方内容站，
//  因此允许内置；而第三方站点的接入必须走用户自填的仓库（见 docs/source-api.md）。
//  两者的共同点是界面完全一样——都通过 `MangaDataSource` 暴露。
//
//  凭据存储的取舍：apiKey / 密码存在同一个 JSON 里，放在 Application Support。
//  这不是钥匙串级别的保护（同一台设备上拿到沙盒就能读到），
//  所以：文件所在目录会被标记为「不参与 iCloud 备份」，
//  避免把用户的服务器密钥同步到云上。要再往上走就是钥匙串，留给后续版本。
//

import Foundation
import AppCore

/// 自建服务器种类。
public enum HostedServerKind: String, Codable, Sendable, CaseIterable {
    case komga
    case kavita

    public var displayName: String {
        switch self {
        case .komga: return "Komga"
        case .kavita: return "Kavita"
        }
    }

    /// 对应的来源种类（界面据此显示图标与说明）。
    public var sourceKind: SourceKind {
        switch self {
        case .komga: return .komga
        case .kavita: return .kavita
        }
    }
}

/// 一台自建服务器的连接配置。
public struct HostedServer: Identifiable, Codable, Equatable, Sendable {

    /// 稳定标识，同时也是 `SourceID`。
    ///
    /// 必须是 `ModelValidation.isValidSourceID` 认可的形态
    /// （小写字母数字与 `-`、`_`，不超过 64 字符），
    /// 因此由「种类 + 名称」派生并做去重（见 `makeID`）。
    public let id: String
    public var kind: HostedServerKind
    public var name: String
    /// 服务器地址（可带子路径，例如 `https://nas.local/komga`）。
    public var baseURL: String
    /// API Key（Komga 用 `X-API-Key`；Kavita 用它换取 JWT）。
    public var apiKey: String?
    /// 用户名（Komga 支持 Basic 认证）。
    public var username: String?
    /// 密码（Komga 支持 Basic 认证，一般配合用户名使用）。
    public var password: String?
    public var addedAt: Date

    public init(
        id: String,
        kind: HostedServerKind,
        name: String,
        baseURL: String,
        apiKey: String? = nil,
        username: String? = nil,
        password: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.username = username
        self.password = password
        self.addedAt = addedAt
    }

    public var sourceID: SourceID { SourceID(id) }
    public var sourceKind: SourceKind { kind.sourceKind }

    /// 是否配置了可用的凭据。
    public var hasCredentials: Bool {
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let username, !username.isEmpty { return true }
        return false
    }

    /// 规范化后的地址（去尾斜杠）。空串表示非法。
    public var normalizedBaseURL: String {
        HostedServer.normalizeBaseURL(baseURL)
    }

    /// 去掉尾部斜杠。**只去掉尾部**：`https://a.com/komga/` 与 `https://a.com/komga`
    /// 是同一个地址，而中间的斜杠是路径的一部分。
    public static func normalizeBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// 地址是否可用（http(s) 且带主机名）。
    public static func isValidBaseURL(_ raw: String) -> Bool {
        let value = normalizeBaseURL(raw)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// 由「种类 + 名称」派生一个合法且不冲突的 `SourceID`。
    ///
    /// 为什么要派生而不是让用户填：用户填的 ID 很容易不合法（含中文、空格、
    /// 大写），而报错让人困惑。名称已经足够表达「这是哪台服务器」了。
    public static func makeID(
        kind: HostedServerKind,
        name: String,
        existing: Set<String>
    ) -> String {
        let prefix = kind.rawValue
        var slug = name.lowercased().map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        // 折叠连续的 `-`，并去掉首尾的 `-`
        var collapsed: [Character] = []
        for character in slug {
            if character == "-", collapsed.last == "-" { continue }
            collapsed.append(character)
        }
        slug = collapsed
        while slug.first == "-" { slug.removeFirst() }
        while slug.last == "-" { slug.removeLast() }

        let readable = String(slug.prefix(24))
        var candidate = readable.isEmpty ? prefix : "\(prefix)-\(readable)"
        // 首字符必须是字母或数字（`slug` 已保证，但 `prefix` 也检查一下）
        if let first = candidate.first, !(first.isLetter || first.isNumber) {
            candidate = "\(prefix)-\(candidate)"
        }
        if candidate.count > 64 {
            candidate = String(candidate.prefix(64))
        }
        if !existing.contains(candidate) { return candidate }

        var index = 2
        while true {
            let suffix = "-\(index)"
            let base = String(candidate.prefix(max(1, 64 - suffix.count)))
            let attempt = base + suffix
            if !existing.contains(attempt) { return attempt }
            index += 1
        }
    }
}

/// 服务器配置存储（单个 JSON 文件）。
public final class ServerStore: @unchecked Sendable {

    private let fileURL: URL
    private let fileSystem: SourceFileSystem
    private let lock = NSLock()
    private var cache: [HostedServer]?

    public init(fileURL: URL, fileSystem: SourceFileSystem = DefaultSourceFileSystem()) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        excludeFromBackup()
    }

    /// 目录标记为「不参与 iCloud 备份」：里面存着用户的服务器密钥。
    /// 失败不致命（最坏情况是被同步到用户的云盘），因此只忽略错误。
    private func excludeFromBackup() {
        let directory = fileURL.deletingLastPathComponent()
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: 读

    public func all() -> [HostedServer] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = loadFromDisk()
        cache = loaded
        return loaded
    }

    public func server(id: String) -> HostedServer? {
        all().first { $0.id == id }
    }

    public func sourceIDs() -> [SourceID] {
        all().map(\.sourceID)
    }

    public func isEmpty() -> Bool { all().isEmpty }

    // MARK: 写

    /// 添加一台服务器。`id` 冲突时抛 `AppError.invalidInput`。
    @discardableResult
    public func add(_ server: HostedServer) throws -> HostedServer {
        lock.lock()
        defer { lock.unlock() }
        var current = cache ?? loadFromDisk()
        guard !server.id.isEmpty, ModelValidation.isValidSourceID(server.id) else {
            throw AppError.invalidInput("服务器标识不合法")
        }
        guard !current.contains(where: { $0.id == server.id }) else {
            throw AppError.invalidInput("标识已存在：\(server.id)")
        }
        current.append(server)
        try persist(current)
        cache = current
        return server
    }

    /// 更新一台服务器（按 id 定位）。找不到时抛 `AppError.notFound`。
    public func update(_ server: HostedServer) throws {
        lock.lock()
        defer { lock.unlock() }
        var current = cache ?? loadFromDisk()
        guard let index = current.firstIndex(where: { $0.id == server.id }) else {
            throw AppError.notFound("服务器：\(server.id)")
        }
        current[index] = server
        try persist(current)
        cache = current
    }

    @discardableResult
    public func remove(id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = cache ?? loadFromDisk()
        let before = current.count
        current.removeAll { $0.id == id }
        guard current.count != before else { return false }
        try persist(current)
        cache = current
        return true
    }

    @discardableResult
    public func removeAll() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = (cache ?? loadFromDisk()).count
        try persist([])
        cache = []
        return count
    }

    // MARK: 内部

    private func loadFromDisk() -> [HostedServer] {
        guard fileSystem.exists(at: fileURL) else { return [] }
        guard let data = try? fileSystem.read(from: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 解不出来就当空：配置文件坏了不该让 App 起不来，
        // 但也不能把坏文件当「用户没配过」而悄悄覆盖掉——所以先改名备份。
        if let servers = try? decoder.decode([HostedServer].self, from: data) {
            return servers
        }
        let backup = fileURL.appendingPathExtension("corrupt")
        try? fileSystem.write(data, to: backup)
        return []
    }

    private func persist(_ servers: [HostedServer]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(servers)
            try fileSystem.ensureDirectory(at: fileURL.deletingLastPathComponent())
            try fileSystem.write(data, to: fileURL)
        } catch {
            throw AppError.normalize(error)
        }
    }
}
