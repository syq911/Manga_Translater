//
//  SourceImageLoaderTests.swift
//  MangaTranslaterTests
//
//  图片字节加载：请求头、Cookie、体积上限、非图片响应的识别。
//
//  这一层是封面与漫画页的共同底座，规则错了的表现是「封面全是空白」
//  或「大图永远加载失败」，都不容易从界面看出来，因此在单元层钉住。
//
//  网络用 `RoutedHTTPTransport`（按地址路由、可设响应头），
//  不需要真实网络，也不依赖 JavaScriptCore。
//

import Testing
import Foundation
import AppCore
import ComicNet
@testable import SourceEngine

@Suite("图片字节加载")
struct SourceImageLoaderTests {

    private static let imageURL = "https://cdn.example.com/1.jpg"
    private static let pngBytes = Data(repeating: 0x89, count: 64)

    private func makeLoader(
        transport: RoutedHTTPTransport,
        cookieJar: CookieJar? = nil,
        configuration: SourceImageLoader.Configuration = .init()
    ) -> SourceImageLoader {
        SourceImageLoader(
            cookieJar: cookieJar,
            transport: transport,
            configuration: configuration
        )
    }

    @Test("取回图片字节")
    func loadsImageBytes() async throws {
        let transport = RoutedHTTPTransport()
        transport.setRaw(Self.pngBytes, headers: ["Content-Type": "image/png"], for: Self.imageURL)

        let data = try await makeLoader(transport: transport)
            .imageData(forURL: Self.imageURL, sourceID: SourceID("demo"))
        #expect(data == Self.pngBytes)
    }

    @Test("页级请求头（Referer）会被带上；未指定时用参数兜底")
    func appliesReferer() async throws {
        let transport = RoutedHTTPTransport()
        transport.setRaw(Self.pngBytes, for: Self.imageURL)
        let loader = makeLoader(transport: transport)

        // 1. 页自带 headers
        let page = ComicPage(
            index: 0,
            imageURL: Self.imageURL,
            headers: ["Referer": "https://example.com/ch/1"]
        )
        _ = try await loader.imageData(for: page, sourceID: SourceID("demo"))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Referer") == "https://example.com/ch/1")

        // 2. 页没带 → 用章节页地址兜底
        _ = try await loader.imageData(
            forURL: Self.imageURL,
            sourceID: SourceID("demo"),
            referer: "https://example.com/ch/2"
        )
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Referer") == "https://example.com/ch/2")

        // 3. 页自带时不覆盖
        _ = try await loader.imageData(
            for: page,
            sourceID: SourceID("demo"),
            referer: "https://example.com/ch/3"
        )
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Referer") == "https://example.com/ch/1")
    }

    @Test("自动带上该来源的 Cookie")
    func sendsSourceCookies() async throws {
        let jar = CookieJar()
        let sourceID = SourceID("demo")
        try jar.set(StoredCookie(name: "sid", value: "abc", domain: "cdn.example.com"), for: sourceID)

        let transport = RoutedHTTPTransport()
        transport.setRaw(Self.pngBytes, for: Self.imageURL)
        _ = try await makeLoader(transport: transport, cookieJar: jar)
            .imageData(forURL: Self.imageURL, sourceID: sourceID)

        let cookie = try #require(transport.requests.first?.value(forHTTPHeaderField: "Cookie"))
        #expect(cookie.contains("sid=abc"))
    }

    @Test("明显不是图片的响应（HTML 错误页）被拒绝")
    func rejectsHTMLErrorPage() async throws {
        let transport = RoutedHTTPTransport()
        // 防盗链站点常见的「200 + HTML 错误页」
        transport.set("<html>forbidden</html>", headers: ["Content-Type": "text/html; charset=utf-8"], for: Self.imageURL)

        do {
            _ = try await makeLoader(transport: transport)
                .imageData(forURL: Self.imageURL, sourceID: SourceID("demo"))
            Issue.record("应当抛错")
        } catch let error as SourceImageError {
            guard case let .notAnImage(contentType) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(contentType.contains("html"))
        }
    }

    @Test("octet-stream 与缺失 Content-Type 都按图片接受")
    func acceptsOctetStreamAndMissingHeader() async throws {
        let transport = RoutedHTTPTransport()
        transport.setRaw(Self.pngBytes, headers: ["Content-Type": "application/octet-stream"], for: Self.imageURL)
        transport.setRaw(Self.pngBytes, for: "https://cdn.example.com/2.jpg")
        let loader = makeLoader(transport: transport)

        #expect(try await loader.imageData(forURL: Self.imageURL, sourceID: SourceID("demo")) == Self.pngBytes)
        #expect(
            try await loader.imageData(forURL: "https://cdn.example.com/2.jpg", sourceID: SourceID("demo"))
                == Self.pngBytes
        )
    }

    @Test("空响应被拒绝")
    func rejectsEmptyBody() async throws {
        let transport = RoutedHTTPTransport()
        transport.setRaw(Data(), headers: ["Content-Type": "image/jpeg"], for: Self.imageURL)

        do {
            _ = try await makeLoader(transport: transport)
                .imageData(forURL: Self.imageURL, sourceID: SourceID("demo"))
            Issue.record("应当抛错")
        } catch let error as SourceImageError {
            #expect(error == .emptyResponse)
        }
    }

    @Test("超过体积上限被拒绝")
    func rejectsOversizedImage() async throws {
        let transport = RoutedHTTPTransport()
        transport.setRaw(
            Data(repeating: 0x01, count: 4096),
            headers: ["Content-Type": "image/jpeg"],
            for: Self.imageURL
        )

        do {
            _ = try await makeLoader(
                transport: transport,
                configuration: SourceImageLoader.Configuration(maxBytes: 1024)
            ).imageData(forURL: Self.imageURL, sourceID: SourceID("demo"))
            Issue.record("应当抛错")
        } catch let error as SourceImageError {
            guard case .tooLarge = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("HTTP 错误状态报 unavailable")
    func reportsHTTPFailure() async throws {
        let transport = RoutedHTTPTransport()
        transport.setRaw(Data("nope".utf8), status: 403, for: Self.imageURL)

        do {
            _ = try await makeLoader(transport: transport)
                .imageData(forURL: Self.imageURL, sourceID: SourceID("demo"))
            Issue.record("应当抛错")
        } catch let error as SourceImageError {
            guard case let .unavailable(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("403"))
        }
    }

    @Test("非 http(s) 地址被拒绝，且不发起请求")
    func rejectsUnsupportedScheme() async throws {
        let transport = RoutedHTTPTransport()
        let loader = makeLoader(transport: transport)

        await expectThrowsAsync(SourceImageError.blockedScheme("data")) {
            _ = try await loader.imageData(forURL: "data:image/png;base64,AAAA", sourceID: SourceID("demo"))
        }
        await expectThrowsAsync(SourceImageError.invalidURL("随便写的")) {
            _ = try await loader.imageData(forURL: "随便写的", sourceID: SourceID("demo"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Content-Type 判定：只拒绝明确不是图片的")
    func classifiesContentTypes() {
        #expect(SourceImageLoader.isClearlyNotImage("text/html"))
        #expect(SourceImageLoader.isClearlyNotImage("text/plain; charset=utf-8"))
        #expect(SourceImageLoader.isClearlyNotImage("application/json"))
        #expect(SourceImageLoader.isClearlyNotImage("application/xhtml+xml"))
        #expect(SourceImageLoader.isClearlyNotImage("image/png") == false)
        #expect(SourceImageLoader.isClearlyNotImage("image/jpeg") == false)
        #expect(SourceImageLoader.isClearlyNotImage("application/octet-stream") == false)
    }
}
