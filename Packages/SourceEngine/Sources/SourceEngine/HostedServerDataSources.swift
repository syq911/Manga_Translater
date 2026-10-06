//
//  HostedServerDataSources.swift
//  SourceEngine
//
//  自建服务器（Komga / Kavita）的连接器：把各自的 REST 接口映射成
//  统一的 `MangaDataSource`。
//
//  写这两段映射的三个原则：
//  1. **宽容解析**：用 `JSONSerialization` 而不是 `Codable`。
//     自建服务器的版本差异比第三方 API 大得多（字段增删、类型从数字变字符串），
//     严格模型会在用户升级服务器后直接坏掉。
//  2. **映射即纯函数**：`KomgaMapping` / `KavitaMapping` 里全是
//     「字典进、模型出」的静态方法，可以脱离网络单测——
//     这类代码的错几乎都是字段路径写错，纯函数测试正好打这个点。
//     （没法在 CI 里连真实的 Komga / Kavita，所以只能靠「接口形状 + 单测」把风险压住；
//     真机联调时的偏差应当只需要改映射，不需要动结构。）
//  3. **认证头由连接器自己拼**：图片请求也要它（Komga 的页接口同样要鉴权），
//     所以页请求头随 `ComicPage.headers` 一起返回，由 `SourceImageLoader` 带上。
//

import Foundation
import AppCore
import ComicNet

// MARK: - 共享的 HTTP 与认证

/// 连接器的 HTTP 取值器。
struct HostedServerHTTP: Sendable {

    let client: HTTPClient
    let base: String
    let authHeaders: [String: String]

    init(server: HostedServer, client: HTTPClient) throws {
        guard HostedServer.isValidBaseURL(server.baseURL) else {
            throw HostedServerError.invalidBaseURL(server.baseURL)
        }
        self.client = client
        self.base = server.normalizedBaseURL
        self.authHeaders = Self.headers(for: server)
    }

    /// 认证头。
    ///
    /// Komga 两种都支持：`X-API-Key`（推荐）或 Basic（邮箱 + 密码）。
    /// 有 apiKey 就优先用它——Basic 需要把密码放在每个请求里。
    static func headers(for server: HostedServer) -> [String: String] {
        if let key = server.apiKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            switch server.kind {
            case .komga:
                return ["X-API-Key": key]
            case .kavita:
                // Kavita 的 apiKey 走查询串换 JWT（见 `KavitaSession`），不放这里
                return [:]
            }
        }
        if server.kind == .komga,
           let user = server.username, !user.isEmpty,
           let password = server.password {
            let raw = Data("\(user):\(password)".utf8).base64EncodedString()
            return ["Authorization": "Basic \(raw)"]
        }
        return [:]
    }

    /// 拼一个绝对地址（`path` 以 `/` 开头）。
    func url(_ path: String) -> String {
        base + path
    }

    /// GET 一个 JSON 值。
    ///
    /// - Parameter extraHeaders: 覆盖 / 追加的请求头（例如 Kavita 的 Bearer）。
    func getJSON(
        _ path: String,
        query: [String: String] = [:],
        extraHeaders: [String: String] = [:]
    ) async throws -> Any {
        let target = Self.appendQuery(to: url(path), query: query)
        var headers = authHeaders
        for (key, value) in extraHeaders { headers[key] = value }
        let response: HTTPResponse
        do {
            response = try await client.get(target, headers: headers)
        } catch {
            throw HostedServerError.map(error, target: target)
        }
        return try Self.decode(response, target: target)
    }

    /// 把查询串拼上（值做百分号编码）。
    static func appendQuery(to url: String, query: [String: String]) -> String {
        guard !query.isEmpty else { return url }
        let pairs = query
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(encode(key))=\(encode(value))"
            }
        let separator = url.contains("?") ? "&" : "?"
        return url + separator + pairs.joined(separator: "&")
    }

    /// 查询串的百分号编码。
    ///
    /// 不能用 `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`：
    /// 那个集合**包含 `&` 与 `=`**，搜索关键词里带这两个字符时会直接把查询串拆坏。
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func decode(_ response: HTTPResponse, target: String) throws -> Any {
        guard response.isSuccess else {
            throw HostedServerError.httpStatus(response.statusCode, target)
        }
        guard !response.data.isEmpty else {
            throw HostedServerError.malformedResponse("空响应：\(target)")
        }
        do {
            return try JSONSerialization.jsonObject(with: response.data)
        } catch {
            throw HostedServerError.malformedResponse(
                "不是合法 JSON：\(target)（\(error.localizedDescription)）"
            )
        }
    }
}

/// 连接器错误。
public enum HostedServerError: Error, Equatable {
    case invalidBaseURL(String)
    case noCredentials
    case httpStatus(Int, String)
    case malformedResponse(String)
    case authenticationFailed(String)
    case cancelled
    case unavailable(String)

    public var message: String {
        switch self {
        case let .invalidBaseURL(url): return "服务器地址不合法：\(url)"
        case .noCredentials: return "还没有填写服务器凭据"
        case let .httpStatus(code, target):
            if code == 401 || code == 403 { return "服务器拒绝访问（HTTP \(code)），请检查凭据" }
            // 地址里可能带着 Kavita 的 `apiKey=` 查询参数，错误文案会进诊断日志，
            // 所以统一先脱敏再拼进文案。
            return "服务器返回 HTTP \(code)：\(LogRedaction.redact(target))"
        case let .malformedResponse(reason):
            return "服务器响应无法解析：\(LogRedaction.redact(reason))"
        case let .authenticationFailed(reason): return "登录服务器失败：\(reason)"
        case .cancelled: return "已取消"
        case let .unavailable(reason): return reason
        }
    }

    public var errorDescription: String? { message }

    /// - Parameter target: 出错时填进文案的地址；`HTTPClient` 抛出的错误里不带它，
    ///   而「HTTP 401」不告诉用户是哪个请求，等于没说。
    public static func map(_ error: Error, target: String? = nil) -> HostedServerError {
        if let hosted = error as? HostedServerError { return hosted }
        if let network = error as? NetworkError {
            switch network {
            case let .httpStatus(code, _): return .httpStatus(code, target ?? "")
            case .cancelled: return .cancelled
            case let .invalidURL(value): return .invalidBaseURL(value)
            case let .timeout(seconds): return .unavailable("服务器超时（\(seconds) 秒）")
            case .offline: return .unavailable("网络不可用")
            case let .transport(reason): return .unavailable(reason)
            case let .decoding(reason): return .malformedResponse(reason)
            case let .responseTooLarge(limit): return .unavailable("响应过大（\(limit) 字节）")
            }
        }
        return .unavailable(AppError.normalize(error).localizedDescription)
    }
}

/// 列表分页的统一形态。
struct HostedPage {
    let items: [[String: Any]]
    let hasNextPage: Bool

    static let empty = HostedPage(items: [], hasNextPage: false)

    /// 从「`content` + `last` / `totalPages` / `number`」形态解析（Komga 风格）。
    static func fromPagedContainer(_ value: Any) -> HostedPage {
        guard let dictionary = value as? [String: Any] else { return .empty }
        let items = (dictionary["content"] as? [[String: Any]]) ?? []
        if let last = dictionary["last"] as? Bool {
            return HostedPage(items: items, hasNextPage: !last)
        }
        if let number = Mapping.int(dictionary["number"]),
           let totalPages = Mapping.int(dictionary["totalPages"]) {
            return HostedPage(items: items, hasNextPage: number + 1 < totalPages)
        }
        // 说不清就按「本页装满就还有下一页」保守处理
        if let size = Mapping.int(dictionary["size"]), size > 0 {
            return HostedPage(items: items, hasNextPage: items.count >= size)
        }
        return HostedPage(items: items, hasNextPage: false)
    }
}

// MARK: - 宽容取值

/// 字典取值的宽容工具。
///
/// 自建服务器的字段类型在不同版本间会变（`"number": 1` vs `"number": "1"`），
/// 所有取值都走这里，避免一处一处写 `as?` 组合。
enum Mapping {

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            if isBoolean(number) { return number.boolValue ? "true" : "false" }
            // 整数值不要显示成 "1.0"
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 {
                return String(Int64(double))
            }
            return number.stringValue
        case let array as [Any]:
            // 有些接口把名字放在数组里（例如 Kavita 的作者）
            let parts = array.compactMap { string($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !isBoolean(number) { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !isBoolean(number) { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]]) ?? []
    }

    static func strings(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let array = value as? [Any] { return array.compactMap { string($0) } }
        if let single = string(value) { return [single] }
        return []
    }

    /// 嵌套取值：`dictionary["metadata"]?["title"]`。
    static func nested(_ value: Any?, _ keys: String...) -> Any? {
        var current: Any? = value
        for key in keys {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    /// 真布尔判定：Darwin 上整数 `NSNumber` 也会通过 `as? Bool`。
    static func isBoolean(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }

    /// 日期：ISO8601（含毫秒）、`yyyy-MM-dd`、10/13 位时间戳。
    ///
    /// 用 `ISO8601DateFormatter` 而不是 `Date.ISO8601FormatStyle` 的链式构造：
    /// 后者写 `Date.ISO8601FormatStyle.year()` 会被编译器拒绝
    /// （「instance member 'year' cannot be used on type」），
    /// 要写成 `.init().year()` 才对；`ISO8601DateFormatter` 更直白也更好改。
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !isBoolean(number) {
            return date(fromTimestamp: number.doubleValue)
        }
        guard let text = string(value) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }

        // `yyyy-MM-dd`：不少自建服务器只给到日
        let parts = text.split(separator: "-")
        if parts.count == 3,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
           (1900...9999).contains(year), (1...12).contains(month), (1...31).contains(day) {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
            if let date = calendar.date(from: components) { return date }
        }

        if text.count == 10 || text.count == 13, text.allSatisfy(\.isNumber), let seconds = Double(text) {
            return date(fromTimestamp: seconds)
        }
        return nil
    }

    /// 时间戳：10 位当秒，13 位当毫秒。
    static func date(fromTimestamp raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        let seconds = raw > 100_000_000_000 ? raw / 1000 : raw
        // 1e9 ≈ 2001 年、1e11 ≈ 5138 年：超出这个区间基本不是有效日期
        guard seconds > 100_000_000, seconds < 100_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Komga

/// Komga 连接器。
///
/// 主要接口（Komga 1.x）：
/// - `GET  /api/v1/series?page=&size=&search=&sort=` → `{content:[series], last, ...}`
/// - `GET  /api/v1/series/latest?page=&size=`
/// - `GET  /api/v1/series/{id}`
/// - `GET  /api/v1/series/{id}/books?page=&size=&sort=` → `{content:[book], ...}`
/// - `GET  /api/v1/books/{id}/pages` → `[{number, fileName, mediaType, ...}]`
/// - `GET  /api/v1/books/{id}/pages/{number}` → 图片字节
public struct KomgaDataSource: MangaDataSource, MangaDataSourceProbing {

    public let sourceID: SourceID
    private let server: HostedServer
    private let http: HostedServerHTTP
    private let pageSize: Int

    /// - Throws: 地址不合法时抛错（在构造期就报，而不是第一次请求才报）。
    public init(server: HostedServer, client: HTTPClient, pageSize: Int = 30) throws {
        self.sourceID = server.sourceID
        self.server = server
        self.http = try HostedServerHTTP(server: server, client: client)
        self.pageSize = max(1, pageSize)
    }

    public func popularManga(page: Int) async throws -> MangaListPage {
        let value = try await http.getJSON(
            "/api/v1/series",
            query: [
                "page": String(Self.zeroBased(page)),
                "size": String(pageSize),
                "sort": "metadata.titleSort,asc",
            ]
        )
        return KomgaMapping.listPage(from: value, sourceID: sourceID, base: http.base)
    }

    public func latestUpdates(page: Int) async throws -> MangaListPage {
        let value = try await http.getJSON(
            "/api/v1/series/latest",
            query: ["page": String(Self.zeroBased(page)), "size": String(pageSize)]
        )
        return KomgaMapping.listPage(from: value, sourceID: sourceID, base: http.base)
    }

    public func search(
        page: Int,
        query: String,
        filters: SourceFilterValues
    ) async throws -> MangaListPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var parameters: [String: String] = [
            "page": String(Self.zeroBased(page)),
            "size": String(pageSize),
        ]
        if !trimmed.isEmpty { parameters["search"] = trimmed }
        let value = try await http.getJSON("/api/v1/series", query: parameters)
        return KomgaMapping.listPage(from: value, sourceID: sourceID, base: http.base)
    }

    public func mangaDetails(url: String) async throws -> Manga {
        let identifier = KomgaMapping.seriesID(fromURL: url)
        guard let identifier else { throw HostedServerError.malformedResponse("无法识别的作品地址：\(url)") }
        let value = try await http.getJSON("/api/v1/series/\(identifier)")
        guard let manga = KomgaMapping.manga(from: value, sourceID: sourceID, base: http.base) else {
            throw HostedServerError.malformedResponse("作品 \(identifier) 的字段不完整")
        }
        return manga
    }

    public func chapterList(mangaURL: String, mangaID: String?) async throws -> [Chapter] {
        let identifier = KomgaMapping.seriesID(fromURL: mangaURL)
        guard let identifier else { throw HostedServerError.malformedResponse("无法识别的作品地址：\(mangaURL)") }
        let owner = mangaID ?? Manga.makeID(sourceID: sourceID, url: mangaURL)
        let value = try await http.getJSON(
            "/api/v1/series/\(identifier)/books",
            query: [
                "page": "0",
                "size": String(Self.maxChapters),
                "sort": "metadata.numberSort,asc",
            ]
        )
        return KomgaMapping.chapters(from: value, mangaID: owner, base: http.base)
    }

    public func pageList(chapterURL: String) async throws -> [ComicPage] {
        let identifier = KomgaMapping.bookID(fromURL: chapterURL)
        guard let identifier else { throw HostedServerError.malformedResponse("无法识别的章节地址：\(chapterURL)") }
        let value = try await http.getJSON("/api/v1/books/\(identifier)/pages")
        // 页地址与鉴权头一起给出去：Komga 的图片接口同样要鉴权，
        // 而 `SourceImageLoader` 只认页上的请求头，不认识「来源」。
        return KomgaMapping.pages(
            from: value,
            bookID: identifier,
            base: http.base,
            headers: http.authHeaders
        )
    }

    /// 连接自检：拉一次书库列表。
    public func probe() async throws -> String {
        let value = try await http.getJSON("/api/v1/libraries")
        let names = Mapping.array(value).compactMap { Mapping.string($0["name"]) }
        guard !names.isEmpty else {
            return "连接成功，但服务器上没有书库"
        }
        return "连接成功，共 \(names.count) 个书库"
    }

    /// Komga 的 `page` 从 0 开始，而本项目的 `page` 从 1 开始。
    static func zeroBased(_ page: Int) -> Int { max(0, page - 1) }

    /// 一次取章节的上限。Komga 单本作品的册数一般远小于此。
    static let maxChapters = 500
}

/// Komga 的字段映射（纯函数，可脱离网络单测）。
enum KomgaMapping {

    static func listPage(from value: Any, sourceID: SourceID, base: String) -> MangaListPage {
        let container = HostedPage.fromPagedContainer(value)
        let items = container.items.compactMap { manga(from: $0, sourceID: sourceID, base: base) }
        return MangaListPage(items: items, hasNextPage: container.hasNextPage)
    }

    static func manga(from value: Any, sourceID: SourceID, base: String) -> Manga? {
        guard let dictionary = value as? [String: Any],
              let identifier = Mapping.string(dictionary["id"])
        else { return nil }

        let title = Mapping.string(Mapping.nested(dictionary, "metadata", "title"))
            ?? Mapping.string(dictionary["name"])
            ?? identifier

        var genres = Mapping.strings(Mapping.nested(dictionary, "metadata", "genres"))
        if genres.isEmpty {
            genres = Mapping.strings(Mapping.nested(dictionary, "metadata", "tags"))
        }

        // Komga 的作者是对象数组：`[{name, role}]`
        var authors: [String] = []
        if let list = Mapping.nested(dictionary, "metadata", "authors") as? [[String: Any]] {
            authors = list.compactMap { Mapping.string($0["name"]) }
        }

        let seriesURL = "\(base)/api/v1/series/\(identifier)"
        // 封面走 Komga 的缩略图接口；尺寸交给宿主缓存再缩放
        let cover = "\(base)/api/v1/series/\(identifier)/thumbnail"

        return Manga(
            sourceID: sourceID,
            url: seriesURL,
            title: title,
            author: authors.first,
            artist: nil,
            summary: Mapping.string(Mapping.nested(dictionary, "metadata", "summary")),
            genres: genres,
            status: status(Mapping.string(Mapping.nested(dictionary, "metadata", "status"))),
            coverURL: cover,
            lastUpdated: Mapping.date(dictionary["lastModified"]) ?? Mapping.date(dictionary["created"])
        )
    }

    static func status(_ raw: String?) -> MangaStatus {
        switch raw?.uppercased() {
        case "ONGOING": return .ongoing
        case "ENDED": return .completed
        case "HIATUS": return .hiatus
        case "ABANDONED": return .cancelled
        default: return .unknown
        }
    }

    static func seriesID(fromURL url: String) -> String? {
        lastComponent(of: url, after: "/api/v1/series/")
    }

    static func bookID(fromURL url: String) -> String? {
        lastComponent(of: url, after: "/api/v1/books/")
    }

    /// 取 `marker` 之后的第一个路径片段（去掉查询串与更深的路径）。
    static func lastComponent(of url: String, after marker: String) -> String? {
        guard let range = url.range(of: marker) else { return nil }
        let rest = url[range.upperBound...]
        let segment = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let cleaned = segment.split(separator: "?").first.map(String.init) ?? segment
        return cleaned.isEmpty ? nil : cleaned
    }

    static func chapters(from value: Any, mangaID: String, base: String) -> [Chapter] {
        let container = HostedPage.fromPagedContainer(value)
        return container.items.compactMap { entry -> Chapter? in
            guard let dictionary = entry as? [String: Any],
                  let identifier = Mapping.string(dictionary["id"])
            else { return nil }
            let name = Mapping.string(Mapping.nested(dictionary, "metadata", "title"))
                ?? Mapping.string(dictionary["name"])
                ?? identifier
            let url = "\(base)/api/v1/books/\(identifier)"
            return Chapter(
                mangaID: mangaID,
                url: url,
                name: name,
                chapterNumber: Mapping.double(dictionary["number"])
                    ?? Mapping.double(Mapping.nested(dictionary, "metadata", "number")),
                dateUploaded: Mapping.date(Mapping.nested(dictionary, "metadata", "releaseDate"))
                    ?? Mapping.date(dictionary["created"])
            )
        }
    }

    static func pages(
        from value: Any,
        bookID: String,
        base: String,
        headers: [String: String]
    ) -> [ComicPage] {
        // 接口返回数组；有的版本包在 `content` 里
        let list: [[String: Any]]
        if let array = value as? [[String: Any]] {
            list = array
        } else if let dictionary = value as? [String: Any], let content = dictionary["content"] as? [[String: Any]] {
            list = content
        } else {
            list = []
        }

        // 用返回的 `number` 拼地址，而不是自己按数组下标猜：
        // Komga 的页码基准在版本间变过（0 起 / 1 起），猜错的后果是整章错位一页。
        let pages: [ComicPage] = list.enumerated().compactMap { index, entry in
            let number = Mapping.int(entry["number"]) ?? (index + 1)
            return ComicPage(
                index: index,
                imageURL: "\(base)/api/v1/books/\(bookID)/pages/\(number)",
                headers: headers.isEmpty ? nil : headers
            )
        }
        return pages
    }
}
