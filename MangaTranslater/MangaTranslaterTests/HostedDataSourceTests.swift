//
//  HostedDataSourceTests.swift
//  MangaTranslaterTests
//
//  Komga / Kavita 连接器：请求地址、鉴权、字段映射、分页、错误。
//
//  为什么这些用例值得写细：真机联调一台真实的 Komga 代价很高（要有一台服务器），
//  而这类代码的错几乎集中在三处——**地址拼错、鉴权头放错位置、字段路径写错**。
//  三者都可在纯替身上钉死。
//

import Foundation
import Testing
import AppCore
import ComicNet
import SourceEngine

@Suite("Komga 连接器")
struct KomgaDataSourceTests {

    private static let base = "https://nas.local:25600"

    private static func server(apiKey: String? = "secret") -> HostedServer {
        HostedServer(
            id: "komga-nas",
            kind: .komga,
            name: "NAS",
            baseURL: base,
            apiKey: apiKey
        )
    }

    private static let seriesListJSON = """
    {
      "content": [
        {
          "id": "s1",
          "name": "Demo Series",
          "metadata": {
            "title": "示例作品",
            "status": "ONGOING",
            "genres": ["Action", "Comedy"],
            "summary": "一句话简介",
            "authors": [{"name": "作者甲", "role": "writer"}]
          },
          "lastModified": "2024-05-01T10:00:00Z"
        },
        {
          "id": "s2",
          "name": "No Metadata Title"
        }
      ],
      "totalElements": 2,
      "totalPages": 3,
      "number": 0,
      "size": 30,
      "last": false
    }
    """

    private func makeSource(
        transport: RoutedHTTPTransport,
        apiKey: String? = "secret"
    ) throws -> KomgaDataSource {
        try KomgaDataSource(
            server: Self.server(apiKey: apiKey),
            client: HTTPClient(transport: transport)
        )
    }

    // MARK: 地址与鉴权

    @Test("热门列表：请求地址按 Komga 的约定（page 从 0 开始），并带 API Key")
    func popularRequestShape() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")

        let page = try await makeSource(transport: transport).popularManga(page: 1)
        #expect(page.items.count == 2)

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "secret")
    }

    @Test("翻页时换成 page=1（宿主的 page 从 1 开始）")
    func popularSecondPage() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series?page=1&size=30&sort=metadata.titleSort%2Casc")
        _ = try await makeSource(transport: transport).popularManga(page: 2)
        #expect(transport.requests.count == 1)
    }

    @Test("没有 API Key 时用 Basic 认证")
    func fallsBackToBasicAuth() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")

        var server = Self.server(apiKey: nil)
        server.username = "me@example.com"
        server.password = "pw"
        let source = try KomgaDataSource(server: server, client: HTTPClient(transport: transport))
        _ = try await source.popularManga(page: 1)

        let request = try #require(transport.requests.first)
        let expected = Data("me@example.com:pw".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test("地址非法时在构造期就报错，不用等第一次请求")
    func rejectsInvalidBaseURL() {
        var server = Self.server()
        server.baseURL = "nas.local"
        #expect(throws: HostedServerError.invalidBaseURL("nas.local")) {
            _ = try KomgaDataSource(server: server, client: HTTPClient(transport: RoutedHTTPTransport()))
        }
    }

    // MARK: 映射

    @Test("字段映射：标题取 metadata.title，题材、作者、简介都到位")
    func mapsSeriesFields() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")

        let page = try await makeSource(transport: transport).popularManga(page: 1)
        let first = try #require(page.items.first)
        #expect(first.title == "示例作品")
        #expect(first.genres == ["Action", "Comedy"])
        #expect(first.author == "作者甲")
        #expect(first.summary == "一句话简介")
        #expect(first.status == .ongoing)
        #expect(first.sourceID == SourceID("komga-nas"))
        #expect(first.url == "\(Self.base)/api/v1/series/s1")
        #expect(first.coverURL == "\(Self.base)/api/v1/series/s1/thumbnail")

        // 缺少 metadata 时退回 name
        let second = try #require(page.items.last)
        #expect(second.title == "No Metadata Title")
        #expect(second.status == .unknown)
    }

    @Test("分页：last=false 表示还有下一页")
    func mapsPagination() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")
        let page = try await makeSource(transport: transport).popularManga(page: 1)
        #expect(page.hasNextPage)

        let lastPage = Self.seriesListJSON.replacingOccurrences(of: "\"last\": false", with: "\"last\": true")
        let second = RoutedHTTPTransport()
        second.set(lastPage, for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")
        let first = try await makeSource(transport: second).popularManga(page: 1)
        #expect(first.hasNextPage == false)
    }

    @Test("最新更新走 /series/latest")
    func latestEndpoint() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series/latest?page=0&size=30")
        let page = try await makeSource(transport: transport).latestUpdates(page: 1)
        #expect(page.items.count == 2)
        #expect(transport.requestedURLs == ["\(Self.base)/api/v1/series/latest?page=0&size=30"])
    }

    @Test("搜索：关键词进 search 参数，且特殊字符被正确编码")
    func searchEncodesQuery() async throws {
        let transport = RoutedHTTPTransport()
        let expected = "\(Self.base)/api/v1/series?page=0&search=a%26b%3Dc&size=30"
        transport.set(Self.seriesListJSON, for: expected)

        _ = try await makeSource(transport: transport).search(page: 1, query: "a&b=c", filters: [:])
        #expect(transport.requestedURLs == [expected])
    }

    @Test("搜索：空关键词不发 search 参数（拉全量而不是报错）")
    func searchWithoutQuery() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(Self.seriesListJSON, for: "\(Self.base)/api/v1/series?page=0&size=30")
        _ = try await makeSource(transport: transport).search(page: 1, query: "   ", filters: [:])
        #expect(transport.requestedURLs == ["\(Self.base)/api/v1/series?page=0&size=30"])
    }

    // MARK: 详情与章节

    @Test("详情：从作品地址反解出 series id")
    func detailsFromURL() async throws {
        let transport = RoutedHTTPTransport()
        let single = """
        {"id":"s1","name":"Demo","metadata":{"title":"示例作品","status":"ENDED"}}
        """
        transport.set(single, for: "\(Self.base)/api/v1/series/s1")

        let manga = try await makeSource(transport: transport)
            .mangaDetails(url: "\(Self.base)/api/v1/series/s1")
        #expect(manga.title == "示例作品")
        #expect(manga.status == .completed)
    }

    @Test("无法识别的作品地址报「字段不完整」而不是发一个怪请求")
    func detailsRejectsForeignURL() async throws {
        let transport = RoutedHTTPTransport()
        await expectThrowsAsync(
            HostedServerError.malformedResponse(
                Copy.format("error.hosted.unrecognizedMangaURL", "https://x.com/book/1")
            )
        ) {
            _ = try await makeSource(transport: transport).mangaDetails(url: "https://x.com/book/1")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("章节列表：books 映射成 Chapter，编号与日期都解析出来")
    func mapsChapters() async throws {
        let transport = RoutedHTTPTransport()
        let books = """
        {
          "content": [
            {"id":"b1","number":"1","name":"第 1 话","metadata":{"title":"第 1 话","releaseDate":"2024-01-02"},"created":"2024-01-01T00:00:00Z"},
            {"id":"b2","number":2.5,"name":"第 2.5 话","metadata":{},"created":"2024-02-01T00:00:00Z"}
          ],
          "last": true
        }
        """
        transport.set(
            books,
            for: "\(Self.base)/api/v1/series/s1/books?page=0&size=500&sort=metadata.numberSort%2Casc"
        )

        let chapters = try await makeSource(transport: transport)
            .chapterList(mangaURL: "\(Self.base)/api/v1/series/s1", mangaID: "komga-nas|s1")
        #expect(chapters.count == 2)
        #expect(chapters[0].name == "第 1 话")
        #expect(chapters[0].chapterNumber == 1)
        #expect(chapters[1].chapterNumber == 2.5)
        #expect(chapters[0].url == "\(Self.base)/api/v1/books/b1")
        // 章节主键里的作品 id 用调用方给的（与书架条目对得上）
        #expect(chapters[0].mangaID == "komga-nas|s1")
    }

    // MARK: 页

    @Test("页列表：用返回的 number 拼地址（不猜页码基准），并带上鉴权头")
    func mapsPages() async throws {
        let transport = RoutedHTTPTransport()
        let pages = """
        [
          {"number":1,"fileName":"001.jpg","mediaType":"image/jpeg"},
          {"number":2,"fileName":"002.jpg","mediaType":"image/jpeg"},
          {"number":3,"fileName":"003.jpg","mediaType":"image/jpeg"}
        ]
        """
        transport.set(pages, for: "\(Self.base)/api/v1/books/b1/pages")

        let result = try await makeSource(transport: transport)
            .pageList(chapterURL: "\(Self.base)/api/v1/books/b1")
        #expect(result.count == 3)
        #expect(result.map(\.index) == [0, 1, 2])
        #expect(result[0].imageURL == "\(Self.base)/api/v1/books/b1/pages/1")
        #expect(result[2].imageURL == "\(Self.base)/api/v1/books/b1/pages/3")
        // 图片接口同样要鉴权，所以页级请求头必须带上
        #expect(result[0].headers?["X-API-Key"] == "secret")
    }

    @Test("页列表：接口返回空数组时不给假页")
    func emptyPages() async throws {
        let transport = RoutedHTTPTransport()
        transport.set("[]", for: "\(Self.base)/api/v1/books/b1/pages")
        let result = try await makeSource(transport: transport)
            .pageList(chapterURL: "\(Self.base)/api/v1/books/b1")
        #expect(result.isEmpty)
    }

    // MARK: 错误与自检

    @Test("HTTP 401 报「拒绝访问」并带上地址")
    func reportsUnauthorized() async throws {
        let transport = RoutedHTTPTransport()
        transport.set("nope", status: 401, for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")
        do {
            _ = try await makeSource(transport: transport).popularManga(page: 1)
            Issue.record("应当抛错")
        } catch let error as HostedServerError {
            guard case let .httpStatus(code, _) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(code == 401)
            // 文案来自包层文案表（随语言变化），因此断言**占位符被真的填进去了**：
            // 若哪天退回成 key 字符串，这里立刻会红。
            #expect(error.message.contains("401"))
        }
    }

    @Test("响应不是 JSON 时报「无法解析」")
    func reportsMalformedResponse() async throws {
        let transport = RoutedHTTPTransport()
        transport.set("<html>登录页</html>", for: "\(Self.base)/api/v1/series?page=0&size=30&sort=metadata.titleSort%2Casc")
        do {
            _ = try await makeSource(transport: transport).popularManga(page: 1)
            Issue.record("应当抛错")
        } catch let error as HostedServerError {
            guard case .malformedResponse = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("连接自检：报出书库数量")
    func probeReportsLibraries() async throws {
        let transport = RoutedHTTPTransport()
        transport.set(#"[{"name":"漫画"},{"name":"杂志"}]"#, for: "\(Self.base)/api/v1/libraries")
        let text = try await makeSource(transport: transport).probe()
        #expect(text.contains("2"))
    }

    @Test("连接自检：没有书库时也算连上")
    func probeWithoutLibraries() async throws {
        let transport = RoutedHTTPTransport()
        transport.set("[]", for: "\(Self.base)/api/v1/libraries")
        let text = try await makeSource(transport: transport).probe()
        #expect(text == Copy.text("text.hosted.probeNoLibraries"))
    }
}

// MARK: - Kavita

@Suite("Kavita 连接器")
struct KavitaDataSourceTests {

    private static let base = "https://kav.local:5000"
    private static let authURL = "\(base)/api/Plugin/authenticate?apiKey=k1&pluginName=MangaTranslater"

    private static func server(apiKey: String? = "k1") -> HostedServer {
        HostedServer(id: "kavita-home", kind: .kavita, name: "Home", baseURL: base, apiKey: apiKey)
    }

    private static let seriesJSON = """
    [
      {"id":5,"name":"Demo","localizedName":"示例系列","originalName":"Demo"},
      {"id":6,"name":"Second"}
    ]
    """

    /// 造一个「先认证、再按路径应答」的替身。
    private func makeTransport(
        token: String = "token-1",
        extra: [String: String] = [:]
    ) -> RoutedHTTPTransport {
        let transport = RoutedHTTPTransport()
        transport.set(#"{"token":"\#(token)","apiKey":"k1","username":"me"}"#, for: Self.authURL)
        for (url, body) in extra { transport.set(body, for: url) }
        return transport
    }

    @Test("先换 token：认证请求用 POST，之后的请求用 Bearer")
    func authenticatesFirst() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Series?pageNumber=1&pageSize=30": Self.seriesJSON
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let page = try await source.popularManga(page: 1)
        #expect(page.items.count == 2)

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.absoluteString == Self.authURL)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test("token 只换一次（后续请求复用）")
    func reusesToken() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Series?pageNumber=1&pageSize=30": Self.seriesJSON,
            "\(Self.base)/api/Series?pageNumber=2&pageSize=30": Self.seriesJSON,
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        _ = try await source.popularManga(page: 1)
        _ = try await source.popularManga(page: 2)
        let authCount = transport.requests.filter { $0.url?.absoluteString == Self.authURL }.count
        #expect(authCount == 1)
    }

    @Test("401 时换 token 重试一次（且只重试一次）")
    func refreshesTokenOnUnauthorized() async throws {
        let seriesURL = "\(Self.base)/api/Series?pageNumber=1&pageSize=30"
        let refreshAuthURL = Self.authURL
        let transport = RoutedHTTPTransport()
        // 第一次认证发 token-1，第二次发 token-2
        transport.setBySequence([
            (refreshAuthURL, 200, #"{"token":"token-1"}"#),
            (seriesURL, 401, "nope"),
            (refreshAuthURL, 200, #"{"token":"token-2"}"#),
            (seriesURL, 200, Self.seriesJSON),
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let page = try await source.popularManga(page: 1)
        #expect(page.items.count == 2)

        let auths = transport.requests.filter { $0.url?.absoluteString == refreshAuthURL }
        let series = transport.requests.filter { $0.url?.absoluteString == seriesURL }
        #expect(auths.count == 2)
        #expect(series.count == 2)
        #expect(series.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
    }

    @Test("连续两次 401 不再重试（凭据真的错了就报错，不无限换 token）")
    func givesUpAfterOneRetry() async throws {
        let seriesURL = "\(Self.base)/api/Series?pageNumber=1&pageSize=30"
        let transport = RoutedHTTPTransport()
        transport.setBySequence([
            (Self.authURL, 200, #"{"token":"token-1"}"#),
            (seriesURL, 401, "nope"),
            (Self.authURL, 200, #"{"token":"token-2"}"#),
            (seriesURL, 401, "nope"),
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        do {
            _ = try await source.popularManga(page: 1)
            Issue.record("应当抛错")
        } catch let error as HostedServerError {
            guard case let .httpStatus(code, _) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(code == 401)
        }
        let auths = transport.requests.filter { $0.url?.absoluteString == Self.authURL }
        #expect(auths.count == 2)
    }

    @Test("没有 API Key 时直接报「还没填凭据」，不发请求")
    func requiresCredentials() async throws {
        let transport = RoutedHTTPTransport()
        let source = KavitaDataSource(server: Self.server(apiKey: nil), client: HTTPClient(transport: transport))
        await expectThrowsAsync(HostedServerError.noCredentials) {
            _ = try await source.popularManga(page: 1)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("分页：本页装满就认为还有下一页")
    func paginationByFill() async throws {
        let full = "[" + (0..<30).map { #"{"id":\#($0),"name":"L\#($0)"}"# }.joined(separator: ",") + "]"
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Series?pageNumber=1&pageSize=30": full
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let page = try await source.popularManga(page: 1)
        #expect(page.items.count == 30)
        #expect(page.hasNextPage)

        let small = makeTransport(extra: [
            "\(Self.base)/api/Series?pageNumber=1&pageSize=30": Self.seriesJSON
        ])
        let smallSource = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: small))
        #expect(try await smallSource.popularManga(page: 1).hasNextPage == false)
    }

    @Test("搜索结果按分组返回时把各组的 series 合起来")
    func flattensSearchGroups() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Search/search?queryString=demo": """
            [{"series":[{"id":5,"name":"Demo"}]},{"series":[{"id":7,"name":"Demo 2"}]}]
            """
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let page = try await source.search(page: 1, query: "demo", filters: [:])
        #expect(page.items.map(\.title) == ["Demo", "Demo 2"])
    }

    @Test("空关键词直接给热门，不打搜索接口")
    func emptySearchFallsBackToPopular() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Series?pageNumber=1&pageSize=30": Self.seriesJSON
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let page = try await source.search(page: 1, query: "  ", filters: [:])
        #expect(page.items.count == 2)
        #expect(transport.requestedURLs.contains("\(Self.base)/api/Search/search") == false)
    }

    @Test("章节：卷里的 chapters 拍平，并按章节号排序")
    func flattensVolumesAndSorts() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Series/volumes?seriesId=5": """
            [
              {"id":1,"name":"第 2 卷","number":"2","chapters":[
                {"id":12,"titleName":"第 2 话","number":"2","pages":10}
              ]},
              {"id":2,"name":"第 1 卷","number":"1","chapters":[
                {"id":11,"titleName":"第 1 话","number":"1","pages":8},
                {"id":13,"titleName":"番外","number":"3.5","pages":4}
              ]}
            ]
            """
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let chapters = try await source.chapterList(
            mangaURL: "\(Self.base)/api/Series/5",
            mangaID: "kavita-home|5"
        )
        #expect(chapters.map(\.chapterNumber) == [1, 2, 3.5])
        #expect(chapters[0].name.contains("第 1 话"))
        #expect(chapters[0].url == "\(Self.base)/api/Reader/chapter/11")
        #expect(chapters[0].mangaID == "kavita-home|5")
    }

    @Test("页列表：页数取自 chapter-info，地址带 apiKey，页码从 0 开始")
    func mapsPages() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Reader/chapter-info?chapterId=11": #"{"chapterId":11,"pages":3}"#
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        let pages = try await source.pageList(chapterURL: "\(Self.base)/api/Reader/chapter/11")
        #expect(pages.count == 3)
        #expect(pages[0].imageURL == "\(Self.base)/api/Reader/image?apiKey=k1&chapterId=11&page=0")
        #expect(pages[2].imageURL.contains("page=2"))
        // 图片接口吃查询串鉴权，所以不需要页级请求头
        #expect(pages[0].headers == nil)
    }

    @Test("页列表：chapter-info 说 0 页时报错，而不是给一个空章节")
    func rejectsEmptyChapter() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Reader/chapter-info?chapterId=11": #"{"pages":0}"#
        ])
        let source = KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport))
        await expectThrowsAsync(HostedServerError.malformedResponse(Copy.format("error.hosted.chapterHasNoPages", "11"))) {
            _ = try await source.pageList(chapterURL: "\(Self.base)/api/Reader/chapter/11")
        }
    }

    @Test("连接自检：认证 + 书库列表")
    func probe() async throws {
        let transport = makeTransport(extra: [
            "\(Self.base)/api/Library": #"[{"name":"漫画"}]"#
        ])
        let text = try await KavitaDataSource(server: Self.server(), client: HTTPClient(transport: transport)).probe()
        #expect(text.contains("1"))
    }
}

// MARK: - 日志脱敏

@Suite("日志脱敏")
struct LogRedactionTests {

    @Test("查询串里的密钥被替换成 ***")
    func redactsSecrets() {
        let input = "https://kav.local/api/Reader/image?apiKey=k1&page=0"
        let output = LogRedaction.redact(input)
        #expect(output.contains("apiKey=***"))
        #expect(output.contains("page=0"))
        #expect(output.contains("k1") == false)
    }

    @Test("多个密钥参数都被替换，大小写不敏感")
    func redactsMultiple() {
        let input = "GET /x?APIKEY=abc&token=def&password=ghi"
        let output = LogRedaction.redact(input)
        #expect(output.contains("abc") == false)
        #expect(output.contains("def") == false)
        #expect(output.contains("ghi") == false)
        #expect(output.contains("***"))
    }

    @Test("不含密钥的文本原样返回")
    func leavesOrdinaryTextAlone() {
        let input = "https://example.com/api/v1/series?page=0&size=30"
        #expect(LogRedaction.redact(input) == input)
    }
}
