//
//  SourceRunner.swift
//  SourceEngine
//
//  源 API 契约（以代码形式固化）与执行期沙箱配置。
//
//  契约 v1 的七个方法名在此冻结；脚本是否实现某个方法由
//  `SourceAPIContract.missingMethods(in:)` 做静态预检，
//  真正的执行由 `SourceRuntimeExecuting` 的实现（M2 接入 JavaScriptCore）负责。
//
//  沙箱约束（来自开发手册）：
//  - 单次调用超时 10 秒；
//  - 脚本无法访问文件系统 / 钥匙串 / 其他来源的数据；
//  - 网络请求必须经由 `net` 桥接（自动带上该来源的 Cookie 与节流）。
//

import Foundation
import AppCore

/// 源 API 方法。
public enum SourceAPIMethod: String, CaseIterable, Sendable {
    case popularManga = "getPopularManga"
    case latestUpdates = "getLatestUpdates"
    case searchManga = "getSearchManga"
    case mangaDetails = "getMangaDetails"
    case chapterList = "getChapterList"
    case pageList = "getPageList"
    case filters = "getFilters"

    /// 必需实现的方法。
    public var isRequired: Bool {
        switch self {
        case .popularManga, .searchManga, .mangaDetails, .chapterList, .pageList:
            return true
        case .latestUpdates, .filters:
            return false
        }
    }

    /// 该方法在脚本中的函数签名片段（用于静态预检）。
    public var functionPatterns: [String] {
        ["function \(rawValue)(", "\(rawValue) = function", "\(rawValue): function", "\(rawValue) = async", "const \(rawValue) = "]
    }
}

/// 源 API 契约本体。
public enum SourceAPIContract {

    /// 契约版本。
    public static let version = "1.0"

    /// 必需方法。
    public static var requiredMethods: [SourceAPIMethod] {
        SourceAPIMethod.allCases.filter(\.isRequired)
    }

    /// 可选方法。
    public static var optionalMethods: [SourceAPIMethod] {
        SourceAPIMethod.allCases.filter { !$0.isRequired }
    }

    /// 脚本中缺失的必需方法。
    public static func missingMethods(in script: String) -> [SourceAPIMethod] {
        requiredMethods.filter { method in
            !method.functionPatterns.contains { script.contains($0) }
        }
    }

    /// 静态预检：脚本是否实现了全部必需方法。
    public static func isComplete(_ script: String) -> Bool {
        missingMethods(in: script).isEmpty
    }
}

/// 源执行错误。
public enum SourceRunnerError: Error, Equatable {
    case notInstalled(String)
    case incompleteContract(missing: [String])
    case scriptRejected(String)
    case executionTimeout(seconds: Int)
    case executionFailed(String)
    case invalidResponse(String)
    case cancelled

    public var message: String {
        switch self {
        case let .notInstalled(key):
            return "源未安装：\(key)"
        case let .incompleteContract(missing):
            return "源未实现必需方法：\(missing.joined(separator: ", "))"
        case let .scriptRejected(reason):
            return "源脚本被拒绝：\(reason)"
        case let .executionTimeout(seconds):
            return "源执行超时（\(seconds) 秒）"
        case let .executionFailed(reason):
            return "源执行失败：\(reason)"
        case let .invalidResponse(reason):
            return "源返回数据不合法：\(reason)"
        case .cancelled:
            return "源调用已取消"
        }
    }
}

extension SourceRunnerError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 执行期沙箱配置。
public struct SourceRuntimeConfiguration: Equatable, Sendable {
    /// 单次调用超时（秒）。
    public var callTimeoutSeconds: Int
    /// 单个来源是否允许发起网络请求。
    public var allowsNetworking: Bool
    /// 单次调用可返回的最大字节数。
    public var maxResponseBytes: Int

    public init(
        callTimeoutSeconds: Int = 10,
        allowsNetworking: Bool = true,
        maxResponseBytes: Int = 4 * 1024 * 1024
    ) {
        self.callTimeoutSeconds = max(1, callTimeoutSeconds)
        self.allowsNetworking = allowsNetworking
        self.maxResponseBytes = max(1024, maxResponseBytes)
    }
}

/// 源脚本执行器抽象。M2 将由 JavaScriptCore 实现。
public protocol SourceRuntimeExecuting: Sendable {
    /// 载入脚本（实现方负责创建独立沙箱，不得与其他来源共享全局状态）。
    func load(script: String, meta: SourceScriptMeta) async throws

    /// 调用契约方法，返回 JSON 字符串（由上层解码为模型）。
    func call(_ method: SourceAPIMethod, arguments: [String]) async throws -> String

    /// 释放沙箱资源。
    func teardown() async
}

// MARK: - 类型化门面

/// 源的**类型化门面**：把「调用脚本 + 解码 JSON」合成一次可读的调用。
///
/// 分层理由是刻意的：
/// - `JSSourceRuntime` 只知道「怎么跑 JS」，对模型一无所知；
/// - `SourceResponseDecoder` 只知道「怎么把 JSON 变成模型」，不碰 JS；
/// - 本类型是两者的粘合处，也是**降级策略**的唯一落点
///   （`getLatestUpdates` 缺失时回退热门、`getFilters` 缺失时返回空数组、
///   参数编码、丢弃项写日志）。
///
/// 线程模型：`actor`。同一来源的调用天然串行——JS 上下文不是可重入的，
/// 并发调用同一源只会让状态互相打架。需要并行时请为每个来源各建一个 runner。
public actor SourceRunner {

    private let runtime: SourceRuntimeExecuting
    private let meta: SourceScriptMeta
    private let logSink: @Sendable (String, String) -> Void

    /// 脚本实际实现的方法（静态预检结果；可选方法要靠它做降级）。
    private var supportedMethods: Set<SourceAPIMethod> = []
    private var isLoaded = false

    public init(
        runtime: SourceRuntimeExecuting,
        meta: SourceScriptMeta,
        logSink: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.runtime = runtime
        self.meta = meta
        self.logSink = logSink
    }

    /// 该来源的 ID。
    public var sourceID: SourceID { meta.id }

    /// 该来源的元信息。
    public var sourceMeta: SourceScriptMeta { meta }

    /// 是否已成功载入脚本。
    public var loaded: Bool { isLoaded }

    /// 脚本实现的方法列表（已排序，便于展示与断言）。
    public var implementedMethods: [SourceAPIMethod] {
        SourceAPIMethod.allCases.filter { supportedMethods.contains($0) }
    }

    // MARK: 生命周期

    /// 载入脚本。失败时抛 `SourceRunnerError`（与运行时同一套错误语义）。
    public func load(script: String) async throws {
        supportedMethods = Set(
            SourceAPIMethod.allCases.filter { method in
                method.functionPatterns.contains { script.contains($0) }
            }
        )
        try await runtime.load(script: script, meta: meta)
        isLoaded = true
    }

    /// 释放沙箱；之后任何调用都会抛 `notInstalled`。
    public func teardown() async {
        await runtime.teardown()
        isLoaded = false
        supportedMethods = []
    }

    // MARK: 契约方法

    /// 热门列表（`getPopularManga`）。分页从 1 开始。
    public func popularManga(page: Int = 1) async throws -> MangaListPage {
        try await listPage(method: .popularManga, arguments: [Self.pageArgument(page)])
    }

    /// 最新更新（`getLatestUpdates`）。脚本未实现时**回退到热门列表**（契约 §5.2）。
    public func latestUpdates(page: Int = 1) async throws -> MangaListPage {
        guard supportedMethods.contains(.latestUpdates) else {
            logSink("info", "[源 \(sourceID.rawValue)] 未实现 getLatestUpdates，回退到热门列表")
            return try await popularManga(page: page)
        }
        return try await listPage(method: .latestUpdates, arguments: [Self.pageArgument(page)])
    }

    /// 搜索（`getSearchManga`）。参数顺序严格按契约 §5.1：`(page, query, filters)`。
    public func search(
        page: Int = 1,
        query: String,
        filters: SourceFilterValues = [:]
    ) async throws -> MangaListPage {
        let arguments = [
            Self.pageArgument(page),
            Self.stringArgument(query),
            Self.objectArgument(filters),
        ]
        return try await listPage(method: .searchManga, arguments: arguments)
    }

    /// 作品详情（`getMangaDetails`）。
    public func mangaDetails(url: String) async throws -> Manga {
        let json = try await invoke(.mangaDetails, arguments: [Self.stringArgument(url)])
        return try decoder.mangaDetails(from: json, fallbackURL: url)
    }

    /// 章节列表（`getChapterList`）。
    ///
    /// - Parameter mangaID: 作品主键；省略时按 `"<sourceID>|<mangaURL>"` 派生
    ///   （与 `Manga.makeID` 一致，保证章节主键能对上书架条目）。
    public func chapterList(mangaURL: String, mangaID: String? = nil) async throws -> [Chapter] {
        let json = try await invoke(.chapterList, arguments: [Self.stringArgument(mangaURL)])
        let identifier = mangaID ?? Manga.makeID(sourceID: sourceID, url: mangaURL)
        let outcome = try decoder.chapters(from: json, mangaID: identifier, mangaURL: mangaURL)
        reportSkipped(outcome.skippedItems, method: .chapterList)
        return outcome.value
    }

    /// 页面列表（`getPageList`）。返回顺序即阅读顺序。
    public func pageList(chapterURL: String) async throws -> [ComicPage] {
        let json = try await invoke(.pageList, arguments: [Self.stringArgument(chapterURL)])
        let outcome = try decoder.pages(from: json, chapterURL: chapterURL)
        reportSkipped(outcome.skippedItems, method: .pageList)
        return outcome.value
    }

    /// 筛选项（`getFilters`）。脚本未实现时返回空数组，搜索页照常可用。
    public func filters() async throws -> [SourceFilter] {
        guard supportedMethods.contains(.filters) else { return [] }
        let json = try await invoke(.filters, arguments: [])
        let outcome = try decoder.filters(from: json)
        reportSkipped(outcome.skippedItems, method: .filters)
        return outcome.value
    }

    // MARK: 内部

    private var decoder: SourceResponseDecoder {
        SourceResponseDecoder(sourceID: meta.id, baseURL: meta.baseURL)
    }

    private func listPage(
        method: SourceAPIMethod,
        arguments: [String]
    ) async throws -> MangaListPage {
        let json = try await invoke(method, arguments: arguments)
        let outcome = try decoder.mangaList(from: json)
        reportSkipped(outcome.skippedItems, method: method)
        return outcome.value
    }

    private func invoke(_ method: SourceAPIMethod, arguments: [String]) async throws -> String {
        guard isLoaded else {
            throw SourceRunnerError.notInstalled(sourceID.rawValue)
        }
        do {
            return try await runtime.call(method, arguments: arguments)
        } catch let error as SourceRunnerError {
            throw error
        } catch is CancellationError {
            throw SourceRunnerError.cancelled
        } catch {
            throw SourceRunnerError.executionFailed(error.localizedDescription)
        }
    }

    private func reportSkipped(_ count: Int, method: SourceAPIMethod) {
        guard count > 0 else { return }
        logSink(
            "warn",
            "[源 \(sourceID.rawValue)] \(method.rawValue) 返回的 \(count) 条数据不完整，已跳过"
        )
    }

    // MARK: 参数编码

    /// 契约规定「参数一律以 JSON 片段传递」，因此这里逐个拼字面量。
    ///
    /// 踩过的坑：曾把整个参数数组交给 `JSONSerialization` 编码，
    /// 结果字符串参数被多编码一层（`query` 变成 `"\"query\""`），
    /// 源脚本拿到的是带引号的文本。
    static func pageArgument(_ page: Int) -> String {
        String(max(1, page))
    }

    static func stringArgument(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        ), let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    static func objectArgument(_ values: SourceFilterValues) -> String {
        guard !values.isEmpty else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
