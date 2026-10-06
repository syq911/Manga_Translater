//
//  SourcePageFetcherTests.swift
//  MangaTranslaterTests
//
//  下载抓取器：把「来源」的知识（Cookie、防盗链 Referer、页级请求头）
//  从队列里隔出来之后，这些知识必须被逐条钉住。
//

import Foundation
import Testing
import AppCore
import ComicNet
import ComicDownload
import SourceEngine

@Suite("下载抓取器")
struct SourcePageFetcherTests {

    private func makeJob(
        sourceID: SourceID = SourceID("demo"),
        pageHeaders: [String: [String: String]] = [:],
        headers: [String: String] = [:],
        referer: String? = nil
    ) -> DownloadJob {
        DownloadJob(
            sourceID: sourceID,
            mangaID: "demo|https://example.com/m/1",
            chapterID: "demo|https://example.com/m/1|https://example.com/c/1",
            chapterName: "第 1 话",
            pageURLs: ["https://img.example.com/0.jpg"],
            headers: headers,
            pageHeaders: pageHeaders,
            referer: referer
        )
    }

    private func imageOutcome() -> StubTransport.Outcome {
        .success(data: Data("IMAGE".utf8), statusCode: 200, headers: ["Content-Type": "image/png"])
    }

    @Test("按任务带出来源的 Cookie")
    func attachesSourceCookies() async throws {
        let jar = CookieJar()
        try jar.set(
            StoredCookie(name: "sid", value: "abc123", domain: "img.example.com"),
            for: SourceID("demo")
        )
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(
            imageLoader: SourceImageLoader(cookieJar: jar, transport: transport)
        )

        _ = try await fetcher.fetchPage(
            url: "https://img.example.com/0.jpg",
            headers: [:],
            job: makeJob()
        )

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sid=abc123")
    }

    @Test("别的来源的 Cookie 不会被带过去")
    func doesNotLeakOtherSourcesCookies() async throws {
        let jar = CookieJar()
        try jar.set(
            StoredCookie(name: "sid", value: "other", domain: "img.example.com"),
            for: SourceID("other")
        )
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(
            imageLoader: SourceImageLoader(cookieJar: jar, transport: transport)
        )

        _ = try await fetcher.fetchPage(
            url: "https://img.example.com/0.jpg",
            headers: [:],
            job: makeJob(sourceID: SourceID("demo"))
        )

        #expect(transport.requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("任务上的 Referer 会带上（防盗链站点的必需项）")
    func attachesReferer() async throws {
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(imageLoader: SourceImageLoader(transport: transport))

        _ = try await fetcher.fetchPage(
            url: "https://img.example.com/0.jpg",
            headers: [:],
            job: makeJob(referer: "https://example.com/c/1")
        )

        #expect(transport.requests.first?.value(forHTTPHeaderField: "Referer") == "https://example.com/c/1")
    }

    @Test("页级请求头优先于任务级（契约允许每页自带）")
    func pageHeadersWinOverJobHeaders() async throws {
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(imageLoader: SourceImageLoader(transport: transport))

        let job = makeJob(
            pageHeaders: ["https://img.example.com/0.jpg": ["Referer": "https://cdn.example.com/hotlink"]],
            headers: ["Referer": "https://example.com/c/1"]
        )
        _ = try await fetcher.fetchPage(url: "https://img.example.com/0.jpg", headers: [:], job: job)

        #expect(
            transport.requests.first?.value(forHTTPHeaderField: "Referer")
                == "https://cdn.example.com/hotlink"
        )
    }

    @Test("页级里没写的键回落到任务级")
    func fallsBackToJobHeaders() async throws {
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(imageLoader: SourceImageLoader(transport: transport))

        let job = makeJob(
            pageHeaders: ["https://img.example.com/0.jpg": ["X-Page": "1"]],
            headers: ["Referer": "https://example.com/c/1"]
        )
        _ = try await fetcher.fetchPage(url: "https://img.example.com/0.jpg", headers: [:], job: job)

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Page") == "1")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://example.com/c/1")
    }

    @Test("页级为空字典时用任务级（不会被空字典盖掉）")
    func emptyPageHeadersFallBack() async throws {
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(imageLoader: SourceImageLoader(transport: transport))

        let job = makeJob(
            pageHeaders: ["https://img.example.com/0.jpg": [:]],
            headers: ["Referer": "https://example.com/c/1"]
        )
        _ = try await fetcher.fetchPage(url: "https://img.example.com/0.jpg", headers: [:], job: job)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Referer") == "https://example.com/c/1")
    }

    @Test("没有任务上下文时直接报错，而不是发一个不带登录态的请求")
    func contextFreeCallFailsLoudly() async throws {
        let transport = StubTransport(outcomes: [imageOutcome()])
        let fetcher = SourcePageFetcher(imageLoader: SourceImageLoader(transport: transport))

        do {
            _ = try await fetcher.fetchPage(url: "https://img.example.com/0.jpg", headers: [:])
            Issue.record("应当抛错")
        } catch let error as AppError {
            guard case .invalidInput = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
        // 关键：一个请求都不该发出去
        #expect(transport.requestCount == 0)
    }

    @Test("HTML 错误页不会被当成图片存下来")
    func rejectsHTMLErrorPage() async throws {
        let transport = StubTransport(outcomes: [.success(
            data: Data("<html>请先登录</html>".utf8),
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"]
        )])
        let fetcher = SourcePageFetcher(imageLoader: SourceImageLoader(transport: transport))

        await expectThrowsAsync(SourceImageError.notAnImage("text/html; charset=utf-8")) {
            _ = try await fetcher.fetchPage(
                url: "https://img.example.com/0.jpg",
                headers: [:],
                job: makeJob()
            )
        }
    }
}
