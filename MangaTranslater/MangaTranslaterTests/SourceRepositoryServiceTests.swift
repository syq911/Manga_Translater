//
//  SourceRepositoryServiceTests.swift
//  MangaTranslaterTests
//
//  源仓库服务：拉索引 → 列可装源 → 装脚本 → 查更新。
//
//  测试策略：网络用**按地址路由**的替身（比队列式替身更稳：一次用例里
//  索引与脚本的请求顺序、重试次数都不会影响断言），文件系统用真实临时目录
//  （`SourceStore` 的原子写与回滚本来就是它的一部分，替身反而测不到）。
//

import Testing
import Foundation
import AppCore
import ComicNet
@testable import SourceEngine

// MARK: - 按地址路由的 HTTP 替身

final class RoutedHTTPTransport: HTTPTransporting, @unchecked Sendable {

    struct Response {
        let status: Int
        let data: Data
        /// 响应头（小写键）。检查 `Content-Type` 相关逻辑时需要。
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var routes: [String: Response] = [:]
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var requestedURLs: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    func set(
        _ body: String,
        status: Int = 200,
        headers: [String: String] = [:],
        for url: String
    ) {
        setRaw(Data(body.utf8), status: status, headers: headers, for: url)
    }

    func setRaw(
        _ data: Data,
        status: Int = 200,
        headers: [String: String] = [:],
        for url: String
    ) {
        lock.lock()
        routes[url] = Response(status: status, data: data, headers: headers)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        let route = request.url.flatMap { routes[$0.absoluteString] }
        lock.unlock()

        guard let url = request.url else {
            throw NetworkError.transport("替身收到没有地址的请求")
        }
        let resolved = route ?? Response(status: 404, data: Data("not found".utf8), headers: [:])
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: resolved.status,
            httpVersion: "HTTP/1.1",
            headerFields: resolved.headers.isEmpty ? nil : resolved.headers
        ) else {
            throw NetworkError.transport("无法构造响应")
        }
        return (resolved.data, response)
    }
}

// MARK: - 测试

@Suite("源仓库索引地址")
struct SourceIndexURLTests {

    @Test("三种输入形式都规范到 index.json")
    func normalizesIndexURL() {
        // 用循环而不是参数化：`arguments:` 传元组对参数个数有额外约束，
        // 而这种「输入 → 期望」的小表用循环更直白，失败信息也能自己带上。
        let cases: [(String, String)] = [
            ("https://example.com/repo/", "https://example.com/repo/index.json"),
            ("https://example.com/repo", "https://example.com/repo/index.json"),
            ("https://example.com/repo/index.json", "https://example.com/repo/index.json"),
            ("https://example.com", "https://example.com/index.json"),
        ]
        for (input, expected) in cases {
            #expect(SourceIndexParser.indexURL(for: input) == expected, "\(input) 应规范为 \(expected)")
        }
    }

    @Test("保留端口与 IPv6 方括号")
    func keepsPortAndIPv6() {
        #expect(
            SourceIndexParser.indexURL(for: "http://localhost:8080/repo")
                == "http://localhost:8080/repo/index.json"
        )
        #expect(
            SourceIndexParser.indexURL(for: "http://[::1]/repo/")
                == "http://[::1]/repo/index.json"
        )
    }

    @Test("非法地址一律拒绝")
    func rejectsInvalidURLs() {
        #expect(SourceIndexParser.indexURL(for: "file:///tmp/repo/") == nil)
        #expect(SourceIndexParser.indexURL(for: "https://example.com/repo/?a=1") == nil)
        #expect(SourceIndexParser.indexURL(for: "https://example.com/repo/#x") == nil)
        #expect(SourceIndexParser.indexURL(for: "随便写的") == nil)
        // http 仅限本机（与 SourceTransport 的约定一致）
        #expect(SourceIndexParser.indexURL(for: "http://example.com/repo") == nil)
    }

    @Test("脚本地址由目录推导（无尾斜杠也对）")
    func buildsScriptURL() throws {
        let entry = SourceIndexEntry(name: "n", fileName: "a.js", key: "a", version: "1")
        #expect(
            SourceIndexParser.scriptURL(for: entry, repositoryURL: "https://example.com/repo")
                == "https://example.com/repo/a.js"
        )
        #expect(
            SourceIndexParser.scriptURL(for: entry, repositoryURL: "https://example.com")
                == "https://example.com/a.js"
        )
    }
}

@Suite("源仓库服务")
struct SourceRepositoryServiceTests {

    static let repositoryURL = "https://example.com/repo/"

    static func indexJSON(_ entries: [(name: String, key: String, version: String, fileName: String)]) -> String {
        let items = entries.map { entry in
            """
            {"name":"\(entry.name)","key":"\(entry.key)","version":"\(entry.version)","fileName":"\(entry.fileName)"}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// 一份通过静态校验、实现全部必需方法的源脚本。
    static func script(
        id: String,
        name: String = "示例源",
        version: String = "1.0.0",
        nsfw: Bool = false
    ) -> String {
        """
        const source = {
          id: "\(id)",
          name: "\(name)",
          lang: "all",
          baseUrl: "https://example.com",
          nsfw: \(nsfw),
          version: "\(version)"
        };

        async function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
        async function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
        async function getMangaDetails(url) { return { title: "T", url: url }; }
        async function getChapterList(url) { return []; }
        async function getPageList(url) { return []; }
        """
    }

    private func makeService(
        rootDirectory: URL,
        transport: RoutedHTTPTransport
    ) -> (service: SourceRepositoryService, store: SourceStore) {
        let store = SourceStore(rootDirectory: rootDirectory)
        let client = HTTPClient(
            transport: transport,
            configuration: HTTPClient.Configuration(maxRetries: 0, retryBackoff: [0], timeoutSeconds: 5)
        )
        return (SourceRepositoryService(store: store, client: client), store)
    }

    // MARK: 目录

    @Test("拉取目录并合并本地安装状态")
    func loadsCatalog() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        transport.set(
            Self.indexJSON([
                (name: "甲", key: "alpha", version: "1.0.0", fileName: "alpha.js"),
                (name: "乙", key: "beta", version: "2.0.0", fileName: "beta.js"),
            ]),
            for: Self.repositoryURL + "index.json"
        )
        let (service, store) = makeService(rootDirectory: root, transport: transport)
        try store.install(script: Self.script(id: "alpha", version: "1.0.0"))

        let catalog = try await service.catalog(for: Self.repositoryURL)
        #expect(catalog.entries.count == 2)
        #expect(catalog.availableCount == 1)

        let alpha = try #require(catalog.entries.first { $0.key == "alpha" })
        #expect(alpha.isInstalled)
        #expect(alpha.installedVersion == "1.0.0")
        #expect(alpha.hasUpdate == false)
        #expect(alpha.scriptURL == Self.repositoryURL + "alpha.js")

        let beta = try #require(catalog.entries.first { $0.key == "beta" })
        #expect(beta.isInstalled == false)
        #expect(beta.hasUpdate == false)
        #expect(beta.summary == nil)
    }

    @Test("版本更高时标记为可更新")
    func detectsUpdates() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        transport.set(
            Self.indexJSON([
                (name: "甲", key: "alpha", version: "1.10.0", fileName: "alpha.js"),
                (name: "乙", key: "beta", version: "1.0.0", fileName: "beta.js"),
            ]),
            for: Self.repositoryURL + "index.json"
        )
        let (service, store) = makeService(rootDirectory: root, transport: transport)
        _ = try store.addRepository(Self.repositoryURL)
        try store.install(script: Self.script(id: "alpha", version: "1.9.0"))
        try store.install(script: Self.script(id: "beta", version: "2.0.0"))

        let catalog = try await service.catalog(for: Self.repositoryURL)
        #expect(catalog.updateCount == 1)
        #expect(catalog.entries.first { $0.key == "alpha" }?.hasUpdate == true)
        // 本地比仓库新 → 不该提示更新
        #expect(catalog.entries.first { $0.key == "beta" }?.hasUpdate == false)

        let updates = await service.availableUpdates()
        #expect(updates.map(\.key) == ["alpha"])
    }

    @Test("仓库地址非法时直接报错，不发请求")
    func rejectsInvalidRepository() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        let (service, _) = makeService(rootDirectory: root, transport: transport)
        await expectThrowsAsync(SourceRepositoryError.invalidRepositoryURL("file:///tmp/")) {
            _ = try await service.catalog(for: "file:///tmp/")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("索引 404 / 非法 JSON / 不安全文件名都被拒绝")
    func rejectsBrokenIndex() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        let (service, _) = makeService(rootDirectory: root, transport: transport)

        // 404：没有登记路由 → 替身返回 404。
        // 断言「错误种类 + 原因里含状态码」而不是整串文案：
        // 文案由底层 HTTP 客户端决定（「服务器返回 404」），逐字断言只会白红一轮。
        do {
            _ = try await service.catalog(for: Self.repositoryURL)
            Issue.record("应当抛错")
        } catch let error as SourceRepositoryError {
            guard case let .indexUnavailable(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("404"))
        }

        transport.set("{ 不是 JSON", for: Self.repositoryURL + "index.json")
        do {
            _ = try await service.catalog(for: Self.repositoryURL)
            Issue.record("应当抛错")
        } catch let error as SourceRepositoryError {
            guard case .indexRejected = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }

        // 路径穿越的文件名 → 整份索引被拒（不做部分接受）
        transport.set(
            Self.indexJSON([(name: "甲", key: "alpha", version: "1.0.0", fileName: "../../evil.js")]),
            for: Self.repositoryURL + "index.json"
        )
        do {
            _ = try await service.catalog(for: Self.repositoryURL)
            Issue.record("应当抛错")
        } catch let error as SourceRepositoryError {
            guard case .indexRejected = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    // MARK: 安装

    @Test("安装：下载脚本并落盘")
    func installsFromRepository() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        transport.set(
            Self.indexJSON([(name: "甲", key: "alpha", version: "1.0.0", fileName: "alpha.js")]),
            for: Self.repositoryURL + "index.json"
        )
        transport.set(Self.script(id: "alpha"), for: Self.repositoryURL + "alpha.js")

        let (service, store) = makeService(rootDirectory: root, transport: transport)
        let installed = try await service.install(key: "alpha", from: Self.repositoryURL)

        #expect(installed.key == "alpha")
        #expect(installed.version == "1.0.0")
        #expect(store.isInstalled("alpha"))
        #expect(try store.script(for: "alpha") == Self.script(id: "alpha"))
        // 只发了两次请求：索引 + 脚本
        #expect(transport.requestedURLs == [
            Self.repositoryURL + "index.json",
            Self.repositoryURL + "alpha.js",
        ])
    }

    @Test("安装：索引与脚本的 key 不一致时拒绝，且不落盘")
    func rejectsKeyMismatch() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        let catalogJSON = Self.indexJSON([(name: "甲", key: "alpha", version: "1.0.0", fileName: "alpha.js")])
        transport.set(catalogJSON, for: Self.repositoryURL + "index.json")
        // 索引说 key 是 alpha，脚本里却写着别的 id
        transport.set(Self.script(id: "someoneelse"), for: Self.repositoryURL + "alpha.js")

        let (service, store) = makeService(rootDirectory: root, transport: transport)
        await expectThrowsAsync(
            SourceRepositoryError.keyMismatch(expected: "alpha", actual: "someoneelse")
        ) {
            _ = try await service.install(key: "alpha", from: Self.repositoryURL)
        }
        #expect(store.isInstalled("alpha") == false)
        #expect(store.installedSources().isEmpty)
    }

    @Test("安装：脚本含禁用 API / 非 UTF-8 / HTTP 错误都被拒绝")
    func rejectsBrokenScript() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        let indexJSON = Self.indexJSON([(name: "甲", key: "alpha", version: "1.0.0", fileName: "alpha.js")])
        transport.set(indexJSON, for: Self.repositoryURL + "index.json")
        let (service, store) = makeService(rootDirectory: root, transport: transport)

        // 禁用 API
        transport.set(Self.script(id: "alpha") + "\nfunction bad() { eval(\"1\"); }", for: Self.repositoryURL + "alpha.js")
        await expectScriptUnavailable { try await service.install(key: "alpha", from: Self.repositoryURL) }

        // 非 UTF-8
        transport.setRaw(Data([0xFF, 0xFE, 0x00, 0x01]), status: 200, for: Self.repositoryURL + "alpha.js")
        await expectScriptUnavailable { try await service.install(key: "alpha", from: Self.repositoryURL) }

        // HTTP 500
        transport.set("boom", status: 500, for: Self.repositoryURL + "alpha.js")
        do {
            _ = try await service.install(key: "alpha", from: Self.repositoryURL)
            Issue.record("应当抛错")
        } catch let error as SourceRepositoryError {
            guard case let .scriptUnavailable(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("500"))
        }

        #expect(store.installedSources().isEmpty)
    }

    private func expectScriptUnavailable(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("应当抛错")
        } catch let error as SourceRepositoryError {
            guard case .scriptUnavailable = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test("安装：仓库里没有这个 key")
    func reportsMissingEntry() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        transport.set(
            Self.indexJSON([(name: "甲", key: "alpha", version: "1.0.0", fileName: "alpha.js")]),
            for: Self.repositoryURL + "index.json"
        )
        let (service, _) = makeService(rootDirectory: root, transport: transport)
        await expectThrowsAsync(SourceRepositoryError.entryNotFound("nope")) {
            _ = try await service.install(key: "nope", from: Self.repositoryURL)
        }
    }

    // MARK: 多仓库

    @Test("刷新多个仓库：单个失败不影响其他仓库")
    func toleratesPartialFailure() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        transport.set(
            Self.indexJSON([(name: "甲", key: "alpha", version: "1.0.0", fileName: "alpha.js")]),
            for: "https://good.example.com/" + "index.json"
        )
        let (service, store) = makeService(rootDirectory: root, transport: transport)
        _ = try store.addRepository("https://good.example.com/")
        _ = try store.addRepository("https://bad.example.com/")   // 没有登记路由 → 404

        let results = await service.catalogs()
        #expect(results.count == 2)
        #expect(results.filter(\.isSuccess).count == 1)

        let good = try #require(results.first { $0.isSuccess })
        #expect(good.repositoryURL == "https://good.example.com/")
        #expect(good.catalog?.entries.count == 1)

        let bad = try #require(results.first { !$0.isSuccess })
        #expect(bad.errorMessage?.contains("404") == true)
    }

    @Test("没有添加仓库时刷新结果为空")
    func returnsEmptyWithoutRepositories() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        let (service, _) = makeService(rootDirectory: root, transport: transport)
        let results = await service.catalogs()
        #expect(results.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test("只读下载脚本内容")
    func downloadsScriptContent() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let transport = RoutedHTTPTransport()
        transport.set(Self.script(id: "alpha"), for: Self.repositoryURL + "alpha.js")
        let (service, _) = makeService(rootDirectory: root, transport: transport)
        let entry = RepositoryEntry(
            key: "alpha",
            name: "甲",
            version: "1.0.0",
            repositoryURL: Self.repositoryURL,
            scriptURL: Self.repositoryURL + "alpha.js"
        )
        let content = try await service.scriptContent(of: entry)
        #expect(content.contains("getPopularManga"))
    }
}
