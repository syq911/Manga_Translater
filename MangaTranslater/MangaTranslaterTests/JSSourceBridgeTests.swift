//
//  JSSourceBridgeTests.swift
//  MangaTranslaterTests
//
//  契约 §7 里「宿主注入的桥接能力」的补齐验证。
//
//  为什么单独一个文件：这些能力是**冻结接口**（`docs/source-api.md` §7），
//  源作者照着写，宿主就必须真的提供。文档里的 canonical 示例源用了
//  `net.get` 与 `source.baseUrl`，一旦桥接缺一个名字，示例源就会
//  在运行期炸掉——本文件把每个名字都钉住。
//
//  覆盖：`net.get` / `net.post` / `json.parse` / `json.stringify` /
//  `source.getPreference`、以及请求描述的解码规则。
//

import Testing
import Foundation
import AppCore
@testable import SourceEngine

@Suite("JS 桥接补齐")
struct JSSourceBridgeTests {

    /// 把契约 §7 的能力逐个用一遍，并把结果塞进返回值供断言。
    static let capabilityScript = """
    const source = {
        id: "bridge",
        name: "Bridge",
        baseUrl: "https://example.com"
    };

    async function getPopularManga(page) {
        const got = await net.get("https://example.com/popular?page=" + page, { "X-Token": "abc" });
        const posted = await net.post("https://example.com/submit", "a=1&b=2");
        return {
            mangas: [],
            hasNextPage: false,
            body: got.body,
            ok: got.ok,
            echo: json.parse(got.body),
            token: source.getPreference("token", "none"),
            fallback: source.getPreference("没有这个键", "缺省"),
            language: json.stringify(json.parse('{"a":1}')),
            postedStatus: posted.status,
            helper: getPreference("token", "none")
        };
    }

    async function getSearchManga(page, query, filters) {
        return { mangas: [], hasNextPage: false };
    }

    async function getMangaDetails(url) {
        return { title: "T", url: url };
    }

    async function getChapterList(url) {
        return [];
    }

    async function getPageList(url) {
        return [];
    }
    """

    private func makeEnvironment() async throws -> (
        runtime: JSSourceRuntime,
        transport: StubSourceTransport
    ) {
        let transport = StubSourceTransport()
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: "{\"ok\":true}"),
            for: "https://example.com/popular?page=1"
        )
        transport.setResponse(
            SourceHTTPResult(status: 201, headers: [:], body: "{\"submitted\":true}"),
            for: "https://example.com/submit"
        )

        let preferences = InMemorySourcePreferences()
        preferences.setValue(
            "secret",
            forKey: JSSourceRuntime.preferenceKey(sourceID: SourceID("bridge"), key: "token")
        )

        let meta = try SourceScriptValidator.validate(Self.capabilityScript)
        let runtime = JSSourceRuntime(transport: transport, preferences: preferences)
        try await runtime.load(script: Self.capabilityScript, meta: meta)
        return (runtime, transport)
    }

    private func callCapsule(_ runtime: JSSourceRuntime) async throws -> [String: Any] {
        let result = try await runtime.call(.popularManga, arguments: ["1"])
        let data = try #require(result.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object)
    }

    @Test("net.get：发送 GET 并带上自定义请求头")
    func performsGetRequest() async throws {
        let (runtime, transport) = try await makeEnvironment()
        let object = try await callCapsule(runtime)

        #expect(object["ok"] as? Bool == true)
        let calls = transport.calls
        let first = try #require(calls.first)
        #expect(first.url == "https://example.com/popular?page=1")
        #expect(first.method == "GET")
        #expect(first.headers["X-Token"] == "abc")
    }

    @Test("net.post：发送 POST 并带上请求体")
    func performsPostRequest() async throws {
        let (runtime, transport) = try await makeEnvironment()
        let object = try await callCapsule(runtime)

        #expect(object["postedStatus"] as? Int == 201)
        let calls = transport.calls
        #expect(calls.count == 2)
        let second = try #require(calls.dropFirst().first)
        #expect(second.url == "https://example.com/submit")
        #expect(second.method == "POST")
        #expect(second.body == "a=1&b=2")
    }

    @Test("json.parse / json.stringify：与原生 JSON 行为一致")
    func exposesJSONHelpers() async throws {
        let (runtime, _) = try await makeEnvironment()
        let object = try await callCapsule(runtime)

        let echo = try #require(object["echo"] as? [String: Any])
        #expect(echo["ok"] as? Bool == true)
        #expect(object["language"] as? String == #"{"a":1}"#)
    }

    @Test("source.getPreference：读取本来源的偏好设置，缺省值生效")
    func readsSourcePreferences() async throws {
        let (runtime, _) = try await makeEnvironment()
        let object = try await callCapsule(runtime)

        #expect(object["token"] as? String == "secret")
        #expect(object["fallback"] as? String == "缺省")
        // 独立的 getPreference(...) 与 source.getPreference(...) 走同一份数据
        #expect(object["helper"] as? String == "secret")
    }

    @Test("请求描述解码：net.get / net.post 的选项形状")
    func decodesRequestOptions() throws {
        let get = try JSSourceRuntime.decodeRequest(
            url: "https://example.com/a",
            optionsJSON: #"{"method":"GET","headers":{"X-A":"1"}}"#
        )
        #expect(get.method == "GET")
        #expect(get.headers == ["X-A": "1"])
        #expect(get.body == nil)

        let post = try JSSourceRuntime.decodeRequest(
            url: "https://example.com/b",
            optionsJSON: #"{"method":"POST","headers":{},"body":"x=1","contentType":"application/x-www-form-urlencoded"}"#
        )
        #expect(post.method == "POST")
        #expect(post.body == "x=1")
        #expect(post.contentType == "application/x-www-form-urlencoded")
    }

    @Test("请求描述解码：非法选项退化为默认 GET")
    func decodesMalformedOptions() throws {
        let request = try JSSourceRuntime.decodeRequest(
            url: "https://example.com/a",
            optionsJSON: "不是 JSON"
        )
        #expect(request.method == "GET")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
    }

    @Test("source 对象被冻结时依然能载入（补齐失败不致命）")
    func toleratesFrozenSource() async throws {
        let script = Self.capabilityScript
            .replacingOccurrences(of: "const source = {", with: "const source = Object.freeze({")
            .replacingOccurrences(of: "\n};", with: "\n});")
        // 先确认替换真的生效了——静默失败的字符串替换曾让用例假通过
        #expect(script.contains("Object.freeze("))

        let transport = StubSourceTransport()
        let meta = try SourceScriptValidator.validate(script)
        let runtime = JSSourceRuntime(transport: transport)
        try await runtime.load(script: script, meta: meta)

        // 载入成功、且运行时仍可用：补齐失败只写日志，不该影响源本身
        let chapters = try await runtime.call(.chapterList, arguments: ["\"https://example.com/m/1\""])
        #expect(chapters == "[]")
    }
}
