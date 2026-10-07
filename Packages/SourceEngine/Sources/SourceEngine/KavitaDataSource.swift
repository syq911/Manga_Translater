//
//  KavitaDataSource.swift
//  SourceEngine
//
//  Kavita 连接器。
//
//  与 Komga 的两点结构差异：
//  1. **先换 JWT**：Kavita 的接口要 `Authorization: Bearer <token>`，
//     token 由 `POST /api/Plugin/authenticate?apiKey=…` 换得（有效期约 10 天）。
//     所以这里多一个 `KavitaSession`（actor）缓存 token，
//     遇到 401 时自动重换一次再重试。
//  2. **图片走查询串鉴权**：`/api/Reader/image?chapterId=&page=&apiKey=`，
//     因此页请求头为空——不是漏了鉴权，是这个接口就吃查询串。
//     把 apiKey 放在页地址里要谨慎：地址会进诊断日志，所以日志侧对
//     `apiKey=` 参数做了替换（见 `LogRedaction`）。
//
//  ⚠️ 版本差异：Kavita 的接口在 0.7/0.8 之间改过字段名（例如
//  `pages` / `pageCount`）。映射写成纯函数并单测，真机联调时改映射即可。
//

import Foundation
import AppCore
import ComicNet

/// 日志脱敏：把查询串里的密钥换成占位符。
public enum LogRedaction {
    /// 需要脱敏的查询参数名（小写比较）。
    public static let secretKeys: Set<String> = ["apikey", "api_key", "token", "password", "key"]

    /// 用正则把 `key=value` 中的 value 换成 `***`。
    public static func redact(_ text: String) -> String {
        var result = text
        for key in secretKeys {
            guard let regex = try? NSRegularExpression(
                pattern: "(?i)(\(key)=)([^&\\s\"']+)",
                options: []
            ) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1***"
            )
        }
        return result
    }
}

/// Kavita 的会话（token 缓存 + 自动重认证）。
actor KavitaSession {

    private let server: HostedServer
    private let client: HTTPClient
    private var token: String?

    init(server: HostedServer, client: HTTPClient) {
        self.server = server
        self.client = client
    }

    /// 取当前 token（没有就换一个）。
    func currentToken() async throws -> String {
        if let token { return token }
        return try await authenticate()
    }

    /// 丢弃当前 token 并重新认证（遇到 401 时调用）。
    @discardableResult
    func refreshToken() async throws -> String {
        token = nil
        return try await authenticate()
    }

    private func authenticate() async throws -> String {
        guard let key = server.apiKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            throw HostedServerError.noCredentials
        }
        var http: HostedServerHTTP
        do {
            http = try HostedServerHTTP(server: server, client: client)
        } catch {
            throw HostedServerError.map(error)
        }
        let target = HostedServerHTTP.appendQuery(
            to: http.url("/api/Plugin/authenticate"),
            query: ["apiKey": key, "pluginName": Self.pluginName]
        )
        // 认证用 POST；Kavita 不要求请求体
        let response: HTTPResponse
        do {
            response = try await client.post(target, body: Data(), contentType: "application/json")
        } catch {
            throw HostedServerError.map(error)
        }
        guard response.isSuccess else {
            throw HostedServerError.authenticationFailed("HTTP \(response.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data),
              let dictionary = object as? [String: Any],
              let issued = Mapping.string(dictionary["token"])
        else {
            throw HostedServerError.authenticationFailed(Copy.text("error.hosted.missingToken"))
        }
        token = issued
        return issued
    }

    static let pluginName = "MangaTranslater"
}

/// Kavita 连接器。
public struct KavitaDataSource: MangaDataSource, MangaDataSourceProbing {

    public nonisolated let sourceID: SourceID
    private let server: HostedServer
    private let client: HTTPClient
    private let session: KavitaSession
    private let pageSize: Int

    public init(server: HostedServer, client: HTTPClient, pageSize: Int = 30) {
        self.sourceID = server.sourceID
        self.server = server
        self.client = client
        self.session = KavitaSession(server: server, client: client)
        self.pageSize = max(1, pageSize)
    }

    private var base: String { server.normalizedBaseURL }

    public func popularManga(page: Int) async throws -> MangaListPage {
        let value = try await get(
            "/api/Series",
            query: ["pageNumber": String(max(1, page)), "pageSize": String(pageSize)]
        )
        return KavitaMapping.listPage(from: value, sourceID: sourceID, base: base, pageSize: pageSize)
    }

    public func latestUpdates(page: Int) async throws -> MangaListPage {
        let value = try await get(
            "/api/Series/latest",
            query: ["pageNumber": String(max(1, page)), "pageSize": String(pageSize)]
        )
        return KavitaMapping.listPage(from: value, sourceID: sourceID, base: base, pageSize: pageSize)
    }

    public func search(
        page: Int,
        query: String,
        filters: SourceFilterValues
    ) async throws -> MangaListPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Kavita 的搜索接口不接受空查询，空查询直接给热门更符合预期
            return try await popularManga(page: page)
        }
        let value = try await get("/api/Search/search", query: ["queryString": trimmed])
        // 搜索结果按类型分组返回，把各组里的 series 合起来
        let series = KavitaMapping.seriesFromSearch(value)
        let items = series.compactMap { KavitaMapping.manga(from: $0, sourceID: sourceID, base: base) }
        return MangaListPage(items: items, hasNextPage: false)
    }

    public func mangaDetails(url: String) async throws -> Manga {
        let identifier = KavitaMapping.numericID(fromURL: url, marker: "/api/Series/")
        guard let identifier else { throw HostedServerError.malformedResponse(Copy.format("error.hosted.unrecognizedMangaURL", url)) }
        let value = try await get("/api/Series/\(identifier)")
        guard let manga = KavitaMapping.manga(from: value, sourceID: sourceID, base: base) else {
            throw HostedServerError.malformedResponse(Copy.format("error.hosted.incompleteManga", identifier))
        }
        return manga
    }

    public func chapterList(mangaURL: String, mangaID: String?) async throws -> [Chapter] {
        let identifier = KavitaMapping.numericID(fromURL: mangaURL, marker: "/api/Series/")
        guard let identifier else { throw HostedServerError.malformedResponse(Copy.format("error.hosted.unrecognizedMangaURL", mangaURL)) }
        let owner = mangaID ?? Manga.makeID(sourceID: sourceID, url: mangaURL)
        let value = try await get("/api/Series/volumes", query: ["seriesId": identifier])
        return KavitaMapping.chapters(from: value, mangaID: owner, base: base)
    }

    public func pageList(chapterURL: String) async throws -> [ComicPage] {
        let identifier = KavitaMapping.numericID(fromURL: chapterURL, marker: "/api/Reader/chapter/")
        guard let identifier else { throw HostedServerError.malformedResponse(Copy.format("error.hosted.unrecognizedChapterURL", chapterURL)) }
        // 页数从 chapter-info 取：章节列表里的 `pages` 字段在版本间存在缺失
        let value = try await get("/api/Reader/chapter-info", query: ["chapterId": identifier])
        let count = KavitaMapping.pageCount(from: value)
        guard count > 0 else {
            throw HostedServerError.malformedResponse(Copy.format("error.hosted.chapterHasNoPages", identifier))
        }
        let key = server.apiKey?.trimmingCharacters(in: .whitespaces) ?? ""
        return (0..<count).map { index in
            // Kavita 的页码从 0 开始
            let query = [
                "chapterId": identifier,
                "page": String(index),
                "apiKey": key,
            ]
            return ComicPage(
                index: index,
                imageURL: HostedServerHTTP.appendQuery(to: "\(base)/api/Reader/image", query: query)
            )
        }
    }

    /// 连接自检：先换 token 再拉一次书库列表。
    public func probe() async throws -> String {
        _ = try await session.currentToken()
        let value = try await get("/api/Library")
        let names = Mapping.array(value).compactMap { Mapping.string($0["name"]) }
        guard !names.isEmpty else {
            return Copy.text("text.hosted.probeNoLibraries")
        }
        return Copy.format("text.hosted.probeLibraries", names.count)
    }

    // MARK: 带鉴权的 GET

    private func get(_ path: String, query: [String: String] = [:]) async throws -> Any {
        try await get(path, query: query, isRetry: false)
    }

    private func get(_ path: String, query: [String: String], isRetry: Bool) async throws -> Any {
        let token = try await session.currentToken()
        var http: HostedServerHTTP
        do {
            http = try HostedServerHTTP(server: server, client: client)
        } catch {
            throw HostedServerError.map(error)
        }
        let target = HostedServerHTTP.appendQuery(to: http.url(path), query: query)

        // 注意：非 2xx 是 `HTTPClient` **抛出**的（不是返回一个 isSuccess == false 的响应），
        // 所以「token 过期就换一个」这件事必须在 catch 这一侧判断。
        // 早期实现把判断写在 `guard response.isSuccess` 之后，
        // 那段代码永远执行不到，401 会直接冒给用户。
        let response: HTTPResponse
        do {
            response = try await client.get(target, headers: ["Authorization": "Bearer \(token)"])
        } catch {
            let mapped = HostedServerError.map(error, target: target)
            if case let .httpStatus(code, _) = mapped, code == 401, !isRetry {
                // 只重试一次：凭据真的错了就该报错，而不是无限换 token
                _ = try await session.refreshToken()
                return try await get(path, query: query, isRetry: true)
            }
            throw mapped
        }

        guard response.isSuccess else {
            if response.statusCode == 401, !isRetry {
                _ = try await session.refreshToken()
                return try await get(path, query: query, isRetry: true)
            }
            throw HostedServerError.httpStatus(response.statusCode, target)
        }
        guard !response.data.isEmpty else {
            throw HostedServerError.malformedResponse(Copy.format("error.hosted.emptyResponse", target))
        }
        do {
            return try JSONSerialization.jsonObject(with: response.data)
        } catch {
            throw HostedServerError.malformedResponse(
                Copy.format("error.hosted.notJSON", target, error.localizedDescription)
            )
        }
    }
}

/// Kavita 的字段映射（纯函数，可脱离网络单测）。
enum KavitaMapping {

    static func listPage(
        from value: Any,
        sourceID: SourceID,
        base: String,
        pageSize: Int
    ) -> MangaListPage {
        let items = Mapping.array(value)
            .compactMap { manga(from: $0, sourceID: sourceID, base: base) }
        // Kavita 的分页信息在响应头里，连接器拿不到；按「本页装满就还有下一页」保守处理
        return MangaListPage(items: items, hasNextPage: items.count >= pageSize)
    }

    /// 搜索结果：可能是分组数组（每组含 `series`），也可能是直接一个 series 数组。
    static func seriesFromSearch(_ value: Any) -> [[String: Any]] {
        if let groups = value as? [[String: Any]] {
            let nested = groups.flatMap { Mapping.array($0["series"]) }
            if !nested.isEmpty { return nested }
            // 兜底：如果本身就是 series 数组（没有分组），上面的 flatMap 会得到空
            if groups.contains(where: { $0["id"] != nil }) { return groups }
        }
        return []
    }

    static func manga(from value: Any, sourceID: SourceID, base: String) -> Manga? {
        guard let dictionary = value as? [String: Any],
              let identifier = Mapping.string(dictionary["id"])
        else { return nil }

        let title = Mapping.string(dictionary["localizedName"])
            ?? Mapping.string(dictionary["name"])
            ?? Mapping.string(dictionary["originalName"])
            ?? identifier

        var genres = Mapping.strings(dictionary["genres"])
        if genres.isEmpty {
            // 详情接口把标签分类放在 `tags`
            if let tags = dictionary["tags"] as? [[String: Any]] {
                genres = tags.compactMap { Mapping.string($0["title"]) ?? Mapping.string($0["name"]) }
            }
        }

        let writers = Mapping.strings(dictionary["writers"])
        let cover = "\(base)/api/Image/series-cover?seriesId=\(identifier)"
        return Manga(
            sourceID: sourceID,
            url: "\(base)/api/Series/\(identifier)",
            title: title,
            author: writers.first,
            summary: Mapping.string(dictionary["summary"]),
            genres: genres,
            status: .unknown,
            coverURL: cover,
            lastUpdated: Mapping.date(dictionary["lastChapterAddedUtc"])
                ?? Mapping.date(dictionary["created"])
        )
    }

    /// 章节：`/api/Series/volumes` 返回卷数组，每卷里有 `chapters`。
    static func chapters(from value: Any, mangaID: String, base: String) -> [Chapter] {
        var result: [Chapter] = []
        for volume in Mapping.array(value) {
            let volumeNumber = Mapping.string(volume["number"]) ?? Mapping.string(volume["name"]) ?? ""
            let volumeName = Mapping.string(volume["name"]) ?? volumeNumber
            for chapter in Mapping.array(volume["chapters"]) {
                guard let identifier = Mapping.string(chapter["id"]) else { continue }
                let rawTitle = Mapping.string(chapter["titleName"])
                    ?? Mapping.string(chapter["title"])
                let name = [volumeName, rawTitle]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                result.append(
                    Chapter(
                        mangaID: mangaID,
                        // 章节地址带上 `/api/Reader/chapter/` 前缀，便于从地址反解出 id
                        url: "\(base)/api/Reader/chapter/\(identifier)",
                        name: name.isEmpty ? identifier : name,
                        chapterNumber: Mapping.double(chapter["number"]),
                        dateUploaded: Mapping.date(chapter["created"])
                            ?? Mapping.date(chapter["lastModified"])
                    )
                )
            }
        }
        // 卷内顺序不保证，按章节号排序（没有号的排最后，保持稳定）
        return result.sorted { left, right in
            let l = left.chapterNumber ?? .greatestFiniteMagnitude
            let r = right.chapterNumber ?? .greatestFiniteMagnitude
            if l == r { return left.name < right.name }
            return l < r
        }
    }

    /// 页数：`chapter-info` 的 `pages`（老版本叫 `pageCount`）。
    static func pageCount(from value: Any) -> Int {
        if let dictionary = value as? [String: Any] {
            return Mapping.int(dictionary["pages"])
                ?? Mapping.int(dictionary["pageCount"])
                ?? Mapping.int(dictionary["totalPages"])
                ?? 0
        }
        return Mapping.int(value) ?? 0
    }

    /// 从地址里取数字 id。
    static func numericID(fromURL url: String, marker: String) -> String? {
        guard let range = url.range(of: marker) else { return nil }
        let rest = url[range.upperBound...]
        let segment = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let cleaned = segment.split(separator: "?").first.map(String.init) ?? segment
        return cleaned.isEmpty ? nil : cleaned
    }
}
