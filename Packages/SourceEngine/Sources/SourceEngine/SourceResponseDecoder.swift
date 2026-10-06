//
//  SourceResponseDecoder.swift
//  SourceEngine
//
//  契约返回值 → 宿主模型（`docs/source-api.md` §5.4 的落地）。
//
//  为什么单独一层：脚本返回的是**任意 JSON**，而模型层要求「主键稳定、
//  字段有界、枚举合法」。把这层转换抽出来有三个好处：
//  1. 不依赖 JavaScriptCore，可以纯单测（构造 JSON 字符串即可）；
//  2. 容错策略集中一处，源作者看到的行为可预期；
//  3. `SourceRunner` 只负责「调用 + 把字符串丢进来」，保持哑薄。
//
//  容错总原则（来自契约 §9「容错要求」）：
//  **能给出合理缺省的就给缺省，只有「整份结构不可用」才让调用失败。**
//  具体取舍见各方法注释；被丢弃的条目数量通过 `SourceDecodeOutcome.skippedItems`
//  回传给调用方写诊断日志 —— 静默丢数据比报错更危险。
//

import Foundation
import AppCore

// MARK: - 解码结果

/// 解码结果：值 + 被丢弃的条目数。
///
/// `skippedItems` 存在的意义：源脚本写出 `url: null` 这类条目时，
/// 宿主若直接报错会让整个列表打不开；若静默跳过，用户又不知道少了什么。
/// 折中做法是「跳过 + 计数」，由上层写一条诊断日志。
public struct SourceDecodeOutcome<Value: Sendable>: Sendable {
    public let value: Value
    public let skippedItems: Int

    public init(value: Value, skippedItems: Int = 0) {
        self.value = value
        self.skippedItems = skippedItems
    }

    /// 变换值，保留丢弃计数。
    public func map<Transformed: Sendable>(
        _ transform: (Value) -> Transformed
    ) -> SourceDecodeOutcome<Transformed> {
        SourceDecodeOutcome<Transformed>(value: transform(value), skippedItems: skippedItems)
    }
}

extension SourceDecodeOutcome: Equatable where Value: Equatable {}

// MARK: - 解码器

/// 把脚本返回的 JSON 解码为宿主模型。
///
/// 无状态值类型：所有输入（JSON 文本、基地址）都从参数进来，
/// 因此可以随意跨任务传递与并行使用。
public struct SourceResponseDecoder: Sendable {

    /// 当前来源 ID（用于生成稳定主键）。
    public let sourceID: SourceID
    /// 来源元信息里的基地址；用于把相对地址补全为绝对地址。
    public let baseURL: String?

    public init(sourceID: SourceID, baseURL: String? = nil) {
        self.sourceID = sourceID
        self.baseURL = baseURL
    }

    // MARK: 列表

    /// 解码 `getPopularManga` / `getSearchManga` / `getLatestUpdates` 的返回值。
    ///
    /// 接受三种顶层形态（后两种是容错，契约只要求第一种）：
    /// - `{ mangas: [...], hasNextPage: bool }`；
    /// - 裸数组 `[...]`（等价于 `hasNextPage: false`）；
    /// - `null`（等价于空列表）。
    public func mangaList(from json: String) throws -> SourceDecodeOutcome<MangaListPage> {
        let root = try parseJSON(json)
        guard !Self.isNull(root) else {
            return SourceDecodeOutcome(value: .empty)
        }

        let items: [Any]
        var hasNextPage = false
        if let array = root as? [Any] {
            items = array
        } else if let object = root as? [String: Any] {
            items = object["mangas"] as? [Any] ?? []
            hasNextPage = Self.boolValue(object["hasNextPage"]) ?? false
        } else {
            throw SourceRunnerError.invalidResponse("作品列表不是对象或数组")
        }

        var mangas: [Manga] = []
        var skipped = 0
        for item in items {
            guard let entry = item as? [String: Any] else {
                skipped += 1
                continue
            }
            guard let manga = manga(fromEntry: entry) else {
                skipped += 1
                continue
            }
            mangas.append(manga)
        }
        return SourceDecodeOutcome(
            value: MangaListPage(items: mangas, hasNextPage: hasNextPage && !mangas.isEmpty),
            skippedItems: skipped
        )
    }

    /// 解码 `getMangaDetails` 的返回值。
    ///
    /// - Parameter fallbackURL: 调用时传入的作品地址；返回对象缺 `url` 时用它兜底（契约 §5.1）。
    public func mangaDetails(from json: String, fallbackURL: String) throws -> Manga {
        let root = try parseJSON(json)
        guard let object = root as? [String: Any] else {
            throw SourceRunnerError.invalidResponse("作品详情不是对象")
        }
        let resolvedURL = urlValue(object["url"], bases: [baseURL], allowRawIdentifier: true)
            ?? Self.rawIdentifier(fallbackURL)
        guard !resolvedURL.isEmpty else {
            throw SourceRunnerError.invalidResponse("作品详情缺少可用的 url")
        }
        let title = Self.textValue(object["title"]) ?? Self.titleFromURL(resolvedURL)
        return Manga(
            sourceID: sourceID,
            url: resolvedURL,
            title: title,
            author: Self.textValue(object["author"]),
            artist: Self.textValue(object["artist"]),
            summary: Self.textValue(object["description"]),
            genres: Self.genres(object["genres"]),
            status: Self.status(object["status"]),
            coverURL: urlValue(object["coverUrl"], bases: [resolvedURL, baseURL]),
            lastUpdated: Self.dateValue(Self.firstPresent(object["lastUpdated"], object["lastUpdatedAt"]))
        )
    }

    /// 解码 `getChapterList` 的返回值（顶层必须是数组，`null` 视为空列表）。
    public func chapters(
        from json: String,
        mangaID: String,
        mangaURL: String?
    ) throws -> SourceDecodeOutcome<[Chapter]> {
        let root = try parseJSON(json)
        guard !Self.isNull(root) else {
            return SourceDecodeOutcome(value: [])
        }
        guard let items = root as? [Any] else {
            throw SourceRunnerError.invalidResponse("章节列表不是数组")
        }

        let bases = [mangaURL, baseURL]
        var chapters: [Chapter] = []
        var skipped = 0
        for item in items {
            guard let entry = item as? [String: Any] else {
                skipped += 1
                continue
            }
            guard let chapterURL = urlValue(
                entry["url"],
                bases: bases,
                allowRawIdentifier: true
            ), !chapterURL.isEmpty else {
                skipped += 1
                continue
            }
            let name = Self.textValue(entry["name"]) ?? Self.titleFromURL(chapterURL)
            chapters.append(
                Chapter(
                    mangaID: mangaID,
                    url: chapterURL,
                    name: name,
                    chapterNumber: Self.doubleValue(entry["chapterNumber"]),
                    dateUploaded: Self.dateValue(Self.firstPresent(entry["dateUpload"], entry["dateUploaded"]))
                )
            )
        }
        return SourceDecodeOutcome(value: chapters, skippedItems: skipped)
    }

    /// 解码 `getPageList` 的返回值。
    ///
    /// 元素可以是字符串，也可以是 `{ url, headers }`（契约 §5.4）。
    /// 图片地址**必须**能解析成 http(s) 绝对地址：这里不做「自定义标识」兜底，
    /// 因为图片没有地址就真的取不到内容，留着只会让阅读器显示破图。
    public func pages(
        from json: String,
        chapterURL: String?
    ) throws -> SourceDecodeOutcome<[ComicPage]> {
        let root = try parseJSON(json)
        guard !Self.isNull(root) else {
            return SourceDecodeOutcome(value: [])
        }
        guard let items = root as? [Any] else {
            throw SourceRunnerError.invalidResponse("页面列表不是数组")
        }

        let bases = [chapterURL, baseURL]
        var pages: [ComicPage] = []
        var skipped = 0
        for item in items {
            let raw: Any?
            var headers: [String: String]? = nil
            if let object = item as? [String: Any] {
                raw = object["url"]
                headers = Self.headers(object["headers"])
            } else {
                raw = item
            }
            guard let imageURL = urlValue(raw, bases: bases) else {
                skipped += 1
                continue
            }
            pages.append(ComicPage(index: pages.count, imageURL: imageURL, headers: headers))
        }
        return SourceDecodeOutcome(value: pages, skippedItems: skipped)
    }

    /// 解码 `getFilters` 的返回值（顶层必须是数组，`null` 视为无筛选）。
    public func filters(from json: String) throws -> SourceDecodeOutcome<[SourceFilter]> {
        let root = try parseJSON(json)
        guard !Self.isNull(root) else {
            return SourceDecodeOutcome(value: [])
        }
        guard let items = root as? [Any] else {
            throw SourceRunnerError.invalidResponse("筛选项不是数组")
        }

        var filters: [SourceFilter] = []
        var seen = Set<String>()
        var skipped = 0
        for item in items {
            guard let entry = item as? [String: Any],
                  let key = Self.textValue(entry["key"]),
                  let name = Self.textValue(entry["name"]),
                  let typeName = Self.textValue(entry["type"]),
                  let kind = SourceFilterKind(rawValue: typeName.lowercased()) else {
                skipped += 1
                continue
            }
            // `key` 重复会让界面出现两个同名字段、取值互相覆盖，直接丢后面的
            guard seen.insert(key).inserted else {
                skipped += 1
                continue
            }
            let options = Self.filterOptions(entry["options"])
            // 下拉类没有候选项时界面无从渲染，丢弃并计数
            if kind.requiresOptions && options.isEmpty {
                skipped += 1
                continue
            }
            filters.append(SourceFilter(kind: kind, key: key, name: name, options: options))
        }
        return SourceDecodeOutcome(value: filters, skippedItems: skipped)
    }

    // MARK: 单条目解码

    /// 解码一条 `MangaLite`。`url` 不可用时返回 nil（由调用方计为丢弃）。
    func manga(fromEntry entry: [String: Any]) -> Manga? {
        guard let rawURL = urlValue(entry["url"], allowRawIdentifier: true) else { return nil }
        return Manga(
            sourceID: sourceID,
            url: rawURL,
            title: Self.textValue(entry["title"]) ?? Self.titleFromURL(rawURL),
            genres: Self.genres(entry["genres"]),
            status: Self.status(entry["status"]),
            coverURL: urlValue(entry["coverUrl"], bases: [rawURL]),
            lastUpdated: Self.dateValue(Self.firstPresent(entry["lastUpdated"], entry["lastUpdatedAt"]))
        )
    }

    // MARK: JSON 基础

    /// 解析 JSON 文本（允许顶层是裸标量/数组）。
    func parseJSON(_ json: String) throws -> Any {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceRunnerError.invalidResponse("源返回了空字符串")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw SourceRunnerError.invalidResponse("源返回值不是 UTF-8 文本")
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
            throw SourceRunnerError.invalidResponse("返回值不是合法 JSON：\(preview)")
        }
    }

    static func isNull(_ value: Any?) -> Bool {
        guard let value else { return true }
        return value is NSNull
    }

    /// 取第一个「真正有值」的候选项。
    ///
    /// 为什么需要它：`a ?? b` 只判断 `nil`，而 JSON 里的 `null` 会解码成
    /// `NSNull`（非 nil），于是 `entry["dateUpload"] ?? entry["dateUploaded"]`
    /// 会在前者为 `null` 时白白丢掉后者的值。这里把 `NSNull` 也算作「没有值」。
    static func firstPresent(_ values: Any?...) -> Any? {
        for value in values {
            guard let value else { continue }
            if value is NSNull { continue }
            return value
        }
        return nil
    }
}

// MARK: - 字段取值

extension SourceResponseDecoder {

    /// 文本字段：接受字符串与数字（部分源把 id 当数字返回）。
    static func textValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            let collapsed = ModelValidation.sanitizeTitle(HTMLURL.unescapingSlashes(text))
            return collapsed.isEmpty ? nil : collapsed
        }
        // 布尔不是文本；数字可以（`id: 12` 这类写法）
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// 布尔字段：接受 `true`/`false`、`1`/`0`、`"true"`/`"yes"`/`"1"`。
    static func boolValue(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        guard let text = value as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0", "": return false
        default: return nil
        }
    }

    /// 数值字段：接受数字与数字字符串（`"12.5"`）。
    static func doubleValue(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = Double(trimmed), parsed.isFinite else { return nil }
        return parsed
    }

    /// 日期字段：ISO8601（含/不含毫秒）、`yyyy-MM-dd`、10/13 位时间戳。
    static func dateValue(_ value: Any?) -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            return Self.date(fromTimestamp: number.doubleValue)
        }
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = Self.iso8601Date(trimmed) { return date }
        if let date = Self.dateOnly(trimmed) { return date }
        if (trimmed.count == 10 || trimmed.count == 13),
           trimmed.allSatisfy(\.isNumber),
           let seconds = Double(trimmed) {
            return Self.date(fromTimestamp: seconds)
        }
        return nil
    }

    /// ISO8601 解析：先按带毫秒、再按不带毫秒。
    ///
    /// 用 `ISO8601DateFormatter` 而不是 `Date.ISO8601FormatStyle` 的链式构造，
    /// 是因为后者要拼 `year().month()…` 一串 builder，参数组合多、写错不易发现；
    /// 这里每次调用新建一个 formatter——章节列表最多几百条，代价可以忽略。
    static func iso8601Date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// 只解析 `yyyy-MM-dd`（不少源只给到日）。
    static func dateOnly(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1900...9999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar.date(from: components)
    }

    /// 时间戳：10 位按秒、其余按毫秒（13 位）。
    static func date(fromTimestamp value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        // 1e9 ≈ 2001 年，1e11 ≈ 5138 年：超出这个区间基本不是有效日期
        guard seconds > 100_000_000, seconds < 100_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 状态枚举：容错映射，无法识别一律 `.unknown`（不因一个字段让详情页失败）。
    static func status(_ value: Any?) -> MangaStatus {
        guard let raw = textValue(value)?.lowercased() else { return .unknown }
        switch raw {
        case "ongoing", "publishing", "releasing", "serialization":
            return .ongoing
        case "completed", "complete", "finished", "done":
            return .completed
        case "licensed", "license":
            return .licensed
        case "cancelled", "canceled", "dropped":
            return .cancelled
        case "hiatus", "onhold", "on_hold", "paused":
            return .hiatus
        default:
            return .unknown
        }
    }

    /// 题材列表：接受字符串数组或单个字符串。
    static func genres(_ value: Any?) -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        var raw: [Any] = []
        if let array = value as? [Any] {
            raw = array
        } else if let single = value as? String {
            raw = [single]
        } else {
            return []
        }
        var genres: [String] = []
        for item in raw {
            guard let text = textValue(item), !genres.contains(text) else { continue }
            genres.append(text)
            if genres.count >= 32 { break }
        }
        return genres
    }

    /// 页面请求头：只保留字符串键值，其余忽略。
    static func headers(_ value: Any?) -> [String: String]? {
        guard let object = value as? [String: Any], !object.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in object {
            guard let text = value as? String else { continue }
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !text.isEmpty else { continue }
            headers[name] = text
        }
        return headers.isEmpty ? nil : headers
    }

    static func filterOptions(_ value: Any?) -> [SourceFilterOption] {
        guard let array = value as? [Any] else { return [] }
        var options: [SourceFilterOption] = []
        for item in array {
            guard let entry = item as? [String: Any] else { continue }
            // `value` 允许为空串（契约示例里「全部」就是空值），
            // 因此先看原样是不是字符串，再退到「宽松取文本」。
            var value = ""
            if let text = entry["value"] as? String {
                value = text
            } else if let text = Self.textValue(entry["value"]) {
                value = text
            }
            let label = Self.textValue(entry["label"]) ?? value
            guard !label.isEmpty || !value.isEmpty else { continue }
            options.append(SourceFilterOption(label: label, value: value))
            if options.count >= 200 { break }
        }
        return options
    }
}

// MARK: - 地址处理

extension SourceResponseDecoder {

    /// 按「优先基地址 → 其次基地址」的顺序把可能的相对地址补全。
    ///
    /// - Parameter allowRawIdentifier: 解析不出绝对地址时，是否保留原始字符串
    ///   作为「来源内自定义标识」（契约允许 `url` 不是真正的 URL）。
    ///   作品与章节地址允许；**图片地址不允许**——图片没有可用地址就是取不到内容。
    func urlValue(
        _ value: Any?,
        bases: [String?] = [],
        allowRawIdentifier: Bool = false
    ) -> String? {
        guard let raw = Self.textValue(value) else { return nil }
        var candidates: [String?] = bases
        candidates.append(baseURL)
        for case let base? in candidates {
            if let resolved = HTMLURL.absolute(raw, base: base),
               ModelValidation.isValidURLString(resolved) {
                return resolved
            }
        }
        // 已经是绝对 http(s) 地址时，上面的循环在传入任何可解析基地址时就会命中；
        // 这里再兜一次「没有基地址」的情况。
        if ModelValidation.isValidURLString(raw) {
            return raw
        }
        guard allowRawIdentifier else { return nil }
        let identifier = Self.rawIdentifier(raw)
        return identifier.isEmpty ? nil : identifier
    }

    /// 允许作为「来源内自定义标识」的原始字符串：非空、不含空白。
    ///
    /// 契约允许 `url` 不是真正的 URL（例如 `"series:123"`），
    /// 但绝不能是空白串或带换行的东西——那会让主键变得不可用。
    static func rawIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !trimmed.uppercased().hasPrefix("JAVASCRIPT:")
            && !trimmed.lowercased().hasPrefix("data:")
            && !trimmed.lowercased().hasPrefix("blob:") else { return "" }
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return "" }
        return trimmed
    }

    /// 没有标题时从地址末段派生一个可读标题。
    static func titleFromURL(_ url: String) -> String {
        var candidate = url
        if let queryIndex = candidate.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            candidate = String(candidate[candidate.startIndex..<queryIndex])
        }
        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        let last = candidate.split(separator: "/").last.map(String.init) ?? ""
        let decoded = last.removingPercentEncoding ?? last
        let sanitized = ModelValidation.sanitizeTitle(decoded, maxLength: 120)
        return sanitized.isEmpty ? "未命名" : sanitized
    }
}
