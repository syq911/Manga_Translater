//
//  Models.swift
//  AppCore
//
//  泛化数据模型：与具体内容站点完全解耦。
//
//  设计约定：
//  - 所有 URL 一律以 `String` 存储，便于 Codable 与来源校验；
//    合法性由 `ModelValidation` 统一判定，而不是在模型里隐式信任。
//  - `Manga.id` / `Chapter.id` 由 `(来源, URL)` 稳定派生，保证同一作品
//    在不同会话中 ID 一致（书架、历史、下载均以此为主键）。
//

import Foundation

// MARK: - 来源标识

/// 来源标识（用户添加的在线源，或内置集成：本地文件 / Komga / Kavita）。
public struct SourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// 本地文件（用户导入的 CBZ / ZIP / 图片目录）。
    public static let local = SourceID("local")
    /// Komga 自建服务器。
    public static let komga = SourceID("komga")
    /// Kavita 自建服务器。
    public static let kavita = SourceID("kavita")
}

/// 来源种类。用于 UI 分组与能力判断。
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    /// 内置：本地文件。
    case local
    /// 内置：Komga 服务器。
    case komga
    /// 内置：Kavita 服务器。
    case kavita
    /// 用户添加的第三方仓库源（JS 脚本）。
    case remote
}

// MARK: - 作品

/// 作品连载状态。
public enum MangaStatus: String, Codable, Sendable, CaseIterable {
    case unknown
    case ongoing
    case completed
    case licensed
    case cancelled
    case hiatus
}

/// 作品。
public struct Manga: Identifiable, Hashable, Codable, Sendable {
    /// 稳定主键：`<sourceID>|<url>`。
    public let id: String
    public let sourceID: SourceID
    /// 作品在来源内的地址（绝对 URL 或来源自定义标识）。
    public let url: String
    public var title: String
    public var author: String?
    public var artist: String?
    public var summary: String?
    public var genres: [String]
    public var status: MangaStatus
    public var coverURL: String?
    public var lastUpdated: Date?

    public init(
        sourceID: SourceID,
        url: String,
        title: String,
        author: String? = nil,
        artist: String? = nil,
        summary: String? = nil,
        genres: [String] = [],
        status: MangaStatus = .unknown,
        coverURL: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.id = Manga.makeID(sourceID: sourceID, url: url)
        self.sourceID = sourceID
        self.url = url
        self.title = title
        self.author = author
        self.artist = artist
        self.summary = summary
        self.genres = genres
        self.status = status
        self.coverURL = coverURL
        self.lastUpdated = lastUpdated
    }

    /// 由来源与地址派生稳定 ID。
    public static func makeID(sourceID: SourceID, url: String) -> String {
        "\(sourceID.rawValue)|\(url)"
    }
}

/// 作品列表分页结果。
public struct MangaListPage: Hashable, Sendable {
    public let items: [Manga]
    public let hasNextPage: Bool

    public init(items: [Manga], hasNextPage: Bool) {
        self.items = items
        self.hasNextPage = hasNextPage
    }

    public static let empty = MangaListPage(items: [], hasNextPage: false)
}

// MARK: - 章节

/// 章节。
public struct Chapter: Identifiable, Hashable, Codable, Sendable {
    /// 稳定主键：`<mangaID>|<url>`。
    public let id: String
    /// 所属作品 ID。
    public let mangaID: String
    /// 章节在来源内的地址。
    public let url: String
    public var name: String
    public var chapterNumber: Double?
    public var dateUploaded: Date?
    public var scanlator: String?

    public init(
        mangaID: String,
        url: String,
        name: String,
        chapterNumber: Double? = nil,
        dateUploaded: Date? = nil,
        scanlator: String? = nil
    ) {
        self.id = Chapter.makeID(mangaID: mangaID, url: url)
        self.mangaID = mangaID
        self.url = url
        self.name = name
        self.chapterNumber = chapterNumber
        self.dateUploaded = dateUploaded
        self.scanlator = scanlator
    }

    public static func makeID(mangaID: String, url: String) -> String {
        "\(mangaID)|\(url)"
    }
}

// MARK: - 页面

/// 单页图片引用。`headers` 用于需要 Referer / User-Agent 的来源。
public struct ComicPage: Hashable, Codable, Sendable {
    /// 从 0 开始的页序号。
    public let index: Int
    public let imageURL: String
    public var headers: [String: String]?

    public init(index: Int, imageURL: String, headers: [String: String]? = nil) {
        self.index = index
        self.imageURL = imageURL
        self.headers = headers
    }
}

// MARK: - 来源元信息

/// 来源元信息（脚本声明或内置集成声明）。
public struct SourceMeta: Identifiable, Hashable, Codable, Sendable {
    public let id: SourceID
    public var name: String
    /// BCP-47 语言代码，`all` 表示多语言。
    public var language: String
    public var baseURL: String?
    public var kind: SourceKind
    /// 成人内容标记：默认在 UI 隐藏，需用户显式开启。
    public var isNSFW: Bool
    /// 来源版本号（社区源用于提示更新）。
    public var version: String?
    /// 请求最小间隔（毫秒），0 表示不限速。
    public var rateLimitMilliseconds: Int
    /// 需要登录时的登录页地址（App 用内嵌网页让用户登录并收割 Cookie）。
    public var loginURL: String?
    /// 来源自定义设置的默认值（App 自动渲染设置界面）。
    public var defaultPreferences: [String: String]

    public init(
        id: SourceID,
        name: String,
        language: String = "all",
        baseURL: String? = nil,
        kind: SourceKind = .remote,
        isNSFW: Bool = false,
        version: String? = nil,
        rateLimitMilliseconds: Int = 0,
        loginURL: String? = nil,
        defaultPreferences: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.baseURL = baseURL
        self.kind = kind
        self.isNSFW = isNSFW
        self.version = version
        self.rateLimitMilliseconds = rateLimitMilliseconds
        self.loginURL = loginURL
        self.defaultPreferences = defaultPreferences
    }
}

// MARK: - 书架条目

/// 书架条目：作品 + 阅读进度 + 分类。
public struct LibraryEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { manga.id }
    public var manga: Manga
    public var addedAt: Date
    public var categoryID: String?
    public var lastReadChapterID: String?
    public var lastReadPageIndex: Int?
    /// 最近一次阅读时间（用于「最近阅读」排序；从未阅读为 nil）。
    public var lastReadAt: Date?
    public var unreadCount: Int
    public var isPinned: Bool

    public init(
        manga: Manga,
        addedAt: Date = Date(),
        categoryID: String? = nil,
        lastReadChapterID: String? = nil,
        lastReadPageIndex: Int? = nil,
        lastReadAt: Date? = nil,
        unreadCount: Int = 0,
        isPinned: Bool = false
    ) {
        self.manga = manga
        self.addedAt = addedAt
        self.categoryID = categoryID
        self.lastReadChapterID = lastReadChapterID
        self.lastReadPageIndex = lastReadPageIndex
        self.lastReadAt = lastReadAt
        self.unreadCount = unreadCount
        self.isPinned = isPinned
    }
}

// MARK: - 校验

/// 模型层输入校验。所有外部输入（用户输入、脚本返回值、仓库 JSON）
/// 进入模型前都应过这里，避免非法值污染数据库。
public enum ModelValidation {
    /// 允许的 URL scheme。`http` 仅用于本机调试（localhost / 127.0.0.1）。
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// 校验 URL 字符串是否合法且 scheme 可用。
    public static func isValidURLString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n") else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        guard allowedSchemes.contains(scheme) else { return false }
        if scheme == "http" {
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
        return url.host?.isEmpty == false
    }

    /// 作品标题等展示字段的清洗：去首尾空白、折叠连续空白、限制长度。
    public static func sanitizeTitle(_ value: String, maxLength: Int = 300) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength))
    }

    /// 校验来源 ID：小写字母/数字开头，允许 `-` `_`，长度 1...64。
    public static func isValidSourceID(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        guard let first = value.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard first.isLowercase || first.isNumber else { return false }
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 校验语义化版本（允许 `1`、`1.2`、`1.2.3`，可带 `-pre` 后缀）。
    public static func isValidVersionString(_ value: String) -> Bool {
        let pattern = "^[0-9]+(\\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
