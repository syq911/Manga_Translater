//
//  JSSourceHTMLBridgeTests.swift
//  MangaTranslaterTests
//
//  `html` 桥接的端到端测试：一个**真正用 CSS 选择器提取字段**的源。
//
//  夹具里的源脚本与 `docs/source-api.md` 的示例写法一致
//  （`html.parse` → `doc.select` → `.text()` / `.attr()` / `.length`），
//  这样文档承诺的 API 与实现之间不会悄悄分叉。
//

import Testing
import Foundation
import AppCore
@testable import SourceEngine

@Suite("JS 源 —— HTML 桥接")
struct JSSourceHTMLBridgeTests {

    // MARK: 夹具

    static let sourceScript = """
    const source = {
        id: "html-demo",
        name: "HTML Demo",
        baseUrl: "https://example.com",
        lang: "all"
    };

    async function getPopularManga(page) {
        const res = await net.fetch("https://example.com/list?page=" + page);
        const doc = html.parse(res.body);
        const mangas = doc.select("div.item").map(function (node) {
            return {
                title: node.select("a.title").text(),
                url: node.select("a.title").attr("href"),
                coverUrl: node.select("img").attr("data-src")
            };
        });
        return { mangas: mangas, hasNextPage: doc.select("a.next").length > 0 };
    }

    async function getSearchManga(query, page, filters) {
        const res = await net.fetch("https://example.com/search?q=" + encodeURIComponent(query));
        const doc = html.parse(res.body);
        return {
            mangas: doc.select("li.result").map(function (node) {
                return { title: node.text(), url: node.select("a").attr("href") };
            }),
            hasNextPage: false
        };
    }

    async function getMangaDetails(url) {
        const res = await net.fetch(url);
        const doc = html.parse(res.body);
        return {
            title: doc.select("h1.title").text(),
            url: url,
            author: doc.select("span.author").text(),
            genres: doc.select("span.genre").map(function (node) { return node.text(); }),
            coverUrl: doc.select("img.cover").attr("src")
        };
    }

    async function getChapterList(url) {
        const res = await net.fetch(url);
        const doc = html.parse(res.body);
        return doc.select("ul.chapters li a").map(function (node) {
            return { name: node.text(), url: node.attr("href") };
        });
    }

    async function getPageList(url) {
        const res = await net.fetch(url);
        const doc = html.parse(res.body);
        return doc.select("div.pages img").map(function (node) { return node.attr("src"); });
    }
    """

    static let listHTML = """
    <html><body>
      <div class="list">
        <div class="item"><a class="title" href="/m/1">作品一</a><img data-src="/c/1.jpg" src="/placeholder.png"></div>
        <div class="item"><a class="title" href="/m/2">作品二</a><img data-src="/c/2.jpg" src="/placeholder.png"></div>
      </div>
      <a class="next" href="/list?page=2">下一页</a>
    </body></html>
    """

    static let searchHTML = """
    <html><body>
      <ul>
        <li class="result"><a href="/m/7">搜索结果 A</a></li>
        <li class="result"><a href="/m/8">搜索结果 B</a></li>
      </ul>
    </body></html>
    """

    static let detailHTML = """
    <html><body>
      <h1 class="title">作品详情</h1>
      <span class="author">作者甲</span>
      <span class="genre">奇幻</span>
      <span class="genre">冒险</span>
      <img class="cover" src="/c/cover.jpg">
    </body></html>
    """

    static let chapterHTML = """
    <html><body>
      <ul class="chapters">
        <li><a href="/c/1">第 1 话</a></li>
        <li><a href="/c/2">第 2 话</a></li>
      </ul>
    </body></html>
    """

    static let pageHTML = """
    <html><body>
      <div class="pages">
        <img src="/p/1.jpg"><img src="/p/2.jpg"><img src="/p/3.jpg">
      </div>
    </body></html>
    """

    // MARK: 环境

    private func makeRuntime() async throws -> (JSSourceRuntime, StubSourceTransport) {
        let transport = StubSourceTransport()
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: Self.listHTML),
            for: "https://example.com/list?page=1"
        )
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: Self.searchHTML),
            for: "https://example.com/search?q=%E7%81%AB%E5%BD%B1"
        )
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: Self.detailHTML),
            for: "https://example.com/m/1"
        )
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: Self.chapterHTML),
            for: "https://example.com/m/1/chapters"
        )
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: Self.pageHTML),
            for: "https://example.com/c/1"
        )

        let runtime = JSSourceRuntime(transport: transport)
        let meta = try SourceScriptValidator.validate(Self.sourceScript)
        try await runtime.load(script: Self.sourceScript, meta: meta)
        return (runtime, transport)
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(object as? [String: Any])
    }

    // MARK: 列表提取

    @Test("用选择器提取列表项（子树查询 + 属性）")
    func extractsList() async throws {
        let (runtime, transport) = try await makeRuntime()
        let result = try await runtime.call(.popularManga, arguments: ["1"])
        let payload = try decode(result)

        let mangas = try #require(payload["mangas"] as? [[String: Any]])
        #expect(mangas.count == 2)
        #expect(mangas[0]["title"] as? String == "作品一")
        #expect(mangas[0]["url"] as? String == "/m/1")
        #expect(mangas[0]["coverUrl"] as? String == "/c/1.jpg")
        #expect(mangas[1]["title"] as? String == "作品二")

        // `.length > 0` 用于判断下一页
        #expect(payload["hasNextPage"] as? Bool == true)

        let call = try #require(transport.calls.first)
        #expect(call.url == "https://example.com/list?page=1")
    }

    @Test("集合是真数组：可用索引与 length")
    func collectionBehavesLikeArray() async throws {
        let (runtime, _) = try await makeRuntime()
        let result = try await runtime.call(.popularManga, arguments: ["1"])
        let payload = try decode(result)
        let mangas = try #require(payload["mangas"] as? [[String: Any]])
        // map 的产物长度与选择结果一致
        #expect(mangas.count == 2)
    }

    @Test("搜索：集合的 text() 取第一个元素的文本")
    func searchUsesCollectionText() async throws {
        let (runtime, _) = try await makeRuntime()
        let result = try await runtime.call(.searchManga, arguments: [#""火影""#, "1", "{}"])
        let payload = try decode(result)
        let mangas = try #require(payload["mangas"] as? [[String: Any]])
        #expect(mangas.count == 2)
        #expect(mangas[0]["title"] as? String == "搜索结果 A")
        #expect(mangas[0]["url"] as? String == "/m/7")
    }

    // MARK: 详情与章节

    @Test("详情页：单值 text()、属性、以及集合 map")
    func extractsDetails() async throws {
        let (runtime, _) = try await makeRuntime()
        let result = try await runtime.call(.mangaDetails, arguments: [#""https://example.com/m/1""#])
        let payload = try decode(result)

        #expect(payload["title"] as? String == "作品详情")
        #expect(payload["author"] as? String == "作者甲")
        #expect(payload["coverUrl"] as? String == "/c/cover.jpg")
        #expect(payload["genres"] as? [String] == ["奇幻", "冒险"])
    }

    @Test("章节列表：元素自身的 attr 与 text")
    func extractsChapters() async throws {
        let (runtime, _) = try await makeRuntime()
        let result = try await runtime.call(.chapterList, arguments: [#""https://example.com/m/1/chapters""#])
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8))
        let chapters = try #require(object as? [[String: Any]])

        #expect(chapters.count == 2)
        #expect(chapters[0]["name"] as? String == "第 1 话")
        #expect(chapters[0]["url"] as? String == "/c/1")
        #expect(chapters[1]["url"] as? String == "/c/2")
    }

    @Test("页列表：直接返回字符串数组")
    func extractsPages() async throws {
        let (runtime, _) = try await makeRuntime()
        let result = try await runtime.call(.pageList, arguments: [#""https://example.com/c/1""#])
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8))
        #expect(object as? [String] == ["/p/1.jpg", "/p/2.jpg", "/p/3.jpg"])
    }

    // MARK: 边界

    @Test("选择器写错时返回空集合并记日志，不中断调用")
    func invalidSelectorDoesNotBreakCall() async throws {
        let logs = LogCollector()
        let transport = StubSourceTransport()
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: Self.listHTML),
            for: "https://example.com/list?page=1"
        )
        let runtime = JSSourceRuntime(
            transport: transport,
            logSink: { level, message in logs.append(level: level, message: message) }
        )
        let broken = Self.sourceScript.replacingOccurrences(
            of: "div.item",
            with: "div.item["
        )
        let meta = try SourceScriptValidator.validate(Self.sourceScript)
        try await runtime.load(script: broken, meta: meta)

        let result = try await runtime.call(.popularManga, arguments: ["1"])
        let payload = try decode(result)
        #expect((payload["mangas"] as? [[String: Any]])?.isEmpty == true)
        #expect(payload["hasNextPage"] as? Bool == false)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(logs.all.contains { $0.contains("html 查询失败") })
    }

    @Test("未匹配的选择器：单值取空串，集合取空数组（都不报错）")
    func unmatchedSelectorYieldsEmpty() async throws {
        let transport = StubSourceTransport()
        transport.setResponse(
            SourceHTTPResult(
                status: 200,
                headers: [:],
                body: "<html><body><h1 class=\"title\">只有标题</h1></body></html>"
            ),
            for: "https://example.com/m/1"
        )
        let runtime = JSSourceRuntime(transport: transport)
        let meta = try SourceScriptValidator.validate(Self.sourceScript)
        try await runtime.load(script: Self.sourceScript, meta: meta)

        let result = try await runtime.call(.mangaDetails, arguments: [#""https://example.com/m/1""#])
        let payload = try decode(result)
        #expect(payload["title"] as? String == "只有标题")
        // span.author / span.genre / img.cover 都不存在
        #expect(payload["author"] as? String == "")
        #expect((payload["genres"] as? [String])?.isEmpty == true)
        #expect(payload["coverUrl"] == nil || payload["coverUrl"] is NSNull)
    }

    @Test("空 HTML 也能解析（不崩溃）")
    func handlesEmptyHTML() async throws {
        let transport = StubSourceTransport()
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: ""),
            for: "https://example.com/list?page=1"
        )
        let runtime = JSSourceRuntime(transport: transport)
        let meta = try SourceScriptValidator.validate(Self.sourceScript)
        try await runtime.load(script: Self.sourceScript, meta: meta)

        let result = try await runtime.call(.popularManga, arguments: ["1"])
        let payload = try decode(result)
        #expect((payload["mangas"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("重新装载会清空旧的文档句柄")
    func reloadClearsHandles() async throws {
        let (runtime, _) = try await makeRuntime()
        _ = try await runtime.call(.popularManga, arguments: ["1"])
        let store = await runtime.htmlHandleCount
        #expect(store > 0)

        let meta = try SourceScriptValidator.validate(Self.sourceScript)
        try await runtime.load(script: Self.sourceScript, meta: meta)
        let afterReload = await runtime.htmlHandleCount
        #expect(afterReload == 0)
    }
}

@Suite("HTML 句柄容器")
struct HTMLHandleStoreTests {

    @Test("存入与取出文档")
    func storesAndReads() {
        let store = HTMLHandleStore()
        let handle = store.store(HTMLParser.parse("<p>hi</p>"))
        #expect(store.document(for: handle) != nil)
        #expect(store.document(for: handle + 999) == nil)
    }

    @Test("dispose 释放文档")
    func disposes() {
        let store = HTMLHandleStore()
        let handle = store.store(HTMLParser.parse("<p>hi</p>"))
        store.dispose(handle)
        #expect(store.document(for: handle) == nil)
        #expect(store.count == 0)
    }

    @Test("超出容量时淘汰最旧的文档")
    func evictsOldest() {
        let store = HTMLHandleStore(capacity: 2)
        let first = store.store(HTMLParser.parse("<p>1</p>"))
        let second = store.store(HTMLParser.parse("<p>2</p>"))
        let third = store.store(HTMLParser.parse("<p>3</p>"))

        #expect(store.count == 2)
        #expect(store.document(for: first) == nil)
        #expect(store.document(for: second) != nil)
        #expect(store.document(for: third) != nil)
    }

    @Test("removeAll 清空")
    func clearsAll() {
        let store = HTMLHandleStore()
        _ = store.store(HTMLParser.parse("<p>1</p>"))
        _ = store.store(HTMLParser.parse("<p>2</p>"))
        store.removeAll()
        #expect(store.count == 0)
    }

    @Test("按 nodeID 在树里查找元素")
    func findsElementByNodeID() throws {
        let document = HTMLParser.parse("<div><p id=\"a\">A</p><p id=\"b\">B</p></div>")
        let target = try #require(try document.selectFirst("#b"))
        let found = document.root.element(withID: target.nodeID)
        #expect(found?.attribute("id") == "b")
        #expect(document.root.element(withID: 999_999) == nil)
    }

    @Test("selectJSON 对失效句柄返回错误对象")
    func selectJSONReportsStaleHandle() throws {
        let store = HTMLHandleStore()
        let json = JSSourceRuntime.selectJSON(store: store, handle: 42, selector: "div", fromNodeID: -1)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["error"] != nil)
    }

    @Test("selectJSON 对非法选择器返回错误对象")
    func selectJSONReportsInvalidSelector() throws {
        let store = HTMLHandleStore()
        let handle = store.store(HTMLParser.parse("<div></div>"))
        let json = JSSourceRuntime.selectJSON(store: store, handle: handle, selector: "div[", fromNodeID: -1)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect((object?["error"] as? String)?.isEmpty == false)
    }

    @Test("selectJSON 返回元素数组")
    func selectJSONReturnsElements() throws {
        let store = HTMLHandleStore()
        let handle = store.store(HTMLParser.parse("<div><a href=\"/1\">A</a><a href=\"/2\">B</a></div>"))
        let json = JSSourceRuntime.selectJSON(store: store, handle: handle, selector: "a", fromNodeID: -1)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let elements = object?["elements"] as? [[String: Any]]
        #expect(elements?.count == 2)
        #expect(elements?[0]["tag"] as? String == "a")
        #expect(elements?[0]["text"] as? String == "A")
        #expect((elements?[0]["attrs"] as? [String: String])?["href"] == "/1")
    }

    @Test("selectJSON 支持从指定节点开始查询")
    func selectJSONScopesToNode() throws {
        let store = HTMLHandleStore()
        let document = HTMLParser.parse("<div class=\"a\"><span>x</span></div><div class=\"b\"><span>y</span></div>")
        let handle = store.store(document)
        let second = try #require(try document.selectFirst(".b"))

        let json = JSSourceRuntime.selectJSON(
            store: store, handle: handle, selector: "span", fromNodeID: second.nodeID
        )
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let elements = object?["elements"] as? [[String: Any]]
        #expect(elements?.count == 1)
        #expect(elements?[0]["text"] as? String == "y")
    }
}
