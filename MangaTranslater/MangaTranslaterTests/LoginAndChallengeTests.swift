//
//  LoginAndChallengeTests.swift
//  MangaTranslaterTests
//
//  登录收割与人工验证识别。
//
//  这两块逻辑在 CI 里没法真跑（没有可登录的网页、也没有 Cloudflare），
//  但它们的规则是纯函数，可以逐条钉死。而它们出错的表现都很「安静」：
//  - 收割不过滤主机 → 把第三方站点的凭据一起存进源容器（安全问题，
//    且用户完全无感）；
//  - 验证页识别过宽 → 正常站点被要求去点验证；
//  - 识别过窄 → 用户看到「没有返回任何作品」，实际只是需要点一下。
//

import Foundation
import Testing
import AppCore
import ComicNet
import SourceEngine

@Suite("登录 Cookie 收割")
struct CookieHarvestTests {

    private func jar() -> CookieJar {
        CookieJar(storageURL: nil)
    }

    private func cookie(
        _ name: String,
        _ value: String,
        domain: String,
        expiresAt: Date? = nil,
        path: String = "/"
    ) -> HarvestedCookie {
        HarvestedCookie(
            name: name,
            value: value,
            domain: domain,
            path: path,
            expiresAt: expiresAt
        )
    }

    // MARK: 主机归属

    @Test("主机归属：同域、子域、父域算自己的；无关域不算")
    func belongsToHost() {
        #expect(CookieHarvest.belongs(domain: "example.com", to: "example.com"))
        #expect(CookieHarvest.belongs(domain: "example.com", to: "www.example.com"))
        #expect(CookieHarvest.belongs(domain: "example.com", to: "img.cdn.example.com"))
        #expect(CookieHarvest.belongs(domain: "", to: "example.com"))
        #expect(CookieHarvest.belongs(domain: "tracker.com", to: "example.com") == false)
        // 后缀但不同域：`notexample.com` 不是 `example.com` 的子域
        #expect(CookieHarvest.belongs(domain: "example.com", to: "notexample.com") == false)
    }

    @Test("前导点与大小写都被归一化（否则后缀匹配永远失败）")
    func normalizesDomain() {
        #expect(HarvestedCookie.normalizeDomain(".Example.com") == "example.com")
        #expect(HarvestedCookie.normalizeDomain("..example.com") == "example.com")
        #expect(HarvestedCookie.normalizeDomain("EXAMPLE.COM") == "example.com")
        #expect(CookieHarvest.belongs(domain: ".Example.com", to: "www.example.com"))
    }

    @Test("从地址取主机名：小写、去端口；非法地址返回 nil")
    func extractsHost() {
        #expect(CookieHarvest.host(of: "https://WWW.Example.com:8443/login") == "www.example.com")
        #expect(CookieHarvest.host(of: "  https://example.com  ") == "example.com")
        #expect(CookieHarvest.host(of: "不是地址") == nil)
    }

    // MARK: 过滤

    @Test("过滤：丢掉过期、无名、以及第三方域的 Cookie")
    func filtersCookies() {
        let now = Date()
        let cookies = [
            cookie("sid", "1", domain: "example.com"),
            cookie("cdn", "1", domain: "cdn.example.com"),
            cookie("ad", "1", domain: "ads.net"),
            cookie("expired", "1", domain: "example.com", expiresAt: now.addingTimeInterval(-60)),
            cookie("", "1", domain: "example.com"),
            cookie("future", "1", domain: "example.com", expiresAt: now.addingTimeInterval(3600)),
        ]
        // 站在 cdn.example.com 上：`example.com` 是父域（收），`cdn.example.com` 同域（收）
        let filtered = CookieHarvest.filter(cookies, forHost: "cdn.example.com", at: now)
        #expect(filtered.map(\.name).sorted() == ["cdn", "future", "sid"])

        // 站在 www.example.com 上：`cdn.example.com` 是**兄弟域**，不算自己的，不收
        let sibling = CookieHarvest.filter(
            [cookie("cdn", "1", domain: "cdn.example.com")],
            forHost: "www.example.com",
            at: now
        )
        #expect(sibling.isEmpty)
    }

    @Test("过滤：宿主存不下的 Cookie（非法名称 / 含换行的值）直接不收")
    func filtersUnstorableCookies() {
        let cookies = [
            cookie("ok", "1", domain: "example.com"),
            cookie("bad=name", "1", domain: "example.com"),
            cookie("bad;name", "1", domain: "example.com"),
            HarvestedCookie(name: "nl", value: "a\nb", domain: "example.com"),
        ]
        let filtered = CookieHarvest.filter(cookies, forHost: "example.com")
        #expect(filtered.map(\.name) == ["ok"])
    }

    @Test("没有主机信息时全收（只在拿不到地址时发生）")
    func keepsAllWithoutHost() {
        let cookies = [
            cookie("sid", "1", domain: "example.com"),
            cookie("ad", "1", domain: "ads.net"),
        ]
        #expect(CookieHarvest.filter(cookies, forHost: nil).count == 2)
    }

    // MARK: 写入容器

    @Test("写入某个来源的容器，其他来源不受影响")
    func mergesIntoSourcesJar() throws {
        let jar = jar()
        let written = CookieHarvest.merge(
            [
                cookie("sid", "abc", domain: "example.com"),
                cookie("ad", "1", domain: "ads.net"),
            ],
            into: jar,
            sourceID: SourceID("demo"),
            forHost: "example.com"
        )
        #expect(written == 1)
        #expect(jar.cookieHeader(for: SourceID("demo"), url: "https://example.com/m/1") == "sid=abc")
        #expect(jar.hasCookies(for: SourceID("other")) == false)
    }

    @Test("重复登录：旧凭据被清掉，新值生效")
    func replaceOldCredentials() throws {
        let jar = jar()
        _ = CookieHarvest.merge(
            [cookie("sid", "old", domain: "example.com")],
            into: jar,
            sourceID: SourceID("demo"),
            forHost: "example.com"
        )
        #expect(jar.cookieHeader(for: SourceID("demo"), url: "https://example.com") == "sid=old")

        _ = CookieHarvest.merge(
            [cookie("sid", "new", domain: "example.com")],
            into: jar,
            sourceID: SourceID("demo"),
            forHost: "example.com"
        )
        // 留着旧 session 会让请求带上两个同名 Cookie，服务端行为不可预测
        #expect(jar.cookieHeader(for: SourceID("demo"), url: "https://example.com") == "sid=new")
    }

    @Test("一条都没收上来时不破坏已有登录状态")
    func keepsExistingWhenNothingAccepted() throws {
        let jar = jar()
        _ = CookieHarvest.merge(
            [cookie("sid", "keep", domain: "example.com")],
            into: jar,
            sourceID: SourceID("demo"),
            forHost: "example.com"
        )
        // 全是第三方域 → 收 0 条，此时**不能**清空已有凭据
        let written = CookieHarvest.merge(
            [cookie("ad", "1", domain: "ads.net")],
            into: jar,
            sourceID: SourceID("demo"),
            forHost: "example.com"
        )
        #expect(written == 0)
        #expect(jar.cookieHeader(for: SourceID("demo"), url: "https://example.com") == "sid=keep")
    }

    @Test("同名同域去重后计数正确")
    func deduplicatesBeforeCounting() throws {
        let jar = jar()
        let written = CookieHarvest.merge(
            [
                cookie("sid", "1", domain: "example.com"),
                cookie("sid", "2", domain: ".Example.com"),
                cookie("token", "t", domain: "example.com"),
            ],
            into: jar,
            sourceID: SourceID("demo"),
            forHost: "example.com"
        )
        #expect(written == 2)
    }

    // MARK: 从属性字典构造

    @Test("从属性字典构造（WebKit 的 HTTPCookie 就是这么给的）")
    func buildsFromProperties() {
        let harvesting = HarvestedCookie(properties: [
            .name: "sid",
            .value: "abc",
            .domain: ".Example.com",
            .path: "/app",
            .secure: "TRUE",
            .expires: Date(timeIntervalSince1970: 1_700_000_000),
        ])
        #expect(harvesting.name == "sid")
        #expect(harvesting.value == "abc")
        #expect(harvesting.path == "/app")
        #expect(harvesting.isSecure)
        #expect(harvesting.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        // 存储时域已归一化
        #expect(harvesting.stored.domain == "example.com")
        #expect(harvesting.stored.isSecure)
    }

    @Test("缺失字段不崩：name/value 退化成空串，path 退化成 /")
    func toleratesMissingProperties() {
        let harvesting = HarvestedCookie(properties: [:])
        #expect(harvesting.name.isEmpty)
        #expect(harvesting.value.isEmpty)
        #expect(harvesting.path == "/")
        #expect(harvesting.isExpired(at: Date()) == false)
    }

    @Test("会话级 Cookie（没有过期时间）永远不会被判成过期")
    func sessionCookieNeverExpires() {
        let harvesting = cookie("sid", "1", domain: "example.com")
        #expect(harvesting.expiresAt == nil)
        #expect(harvesting.isExpired(at: Date()) == false)
    }
}

// MARK: - 验证页识别

@Suite("人工验证页识别")
struct ChallengeDetectorTests {

    @Test("503 + Cloudflare 标记 → 判定为 Cloudflare 校验")
    func detectsCloudflare() {
        let body = "<html><title>Just a moment...</title><div id=\"cf-chl-xxx\"></div></html>"
        let hint = ChallengeDetector.detect(statusCode: 503, body: body, contentType: "text/html")
        #expect(hint?.kind == .cloudflare)
        #expect(hint?.marker == "cf-chl-")
    }

    @Test("403 + reCAPTCHA 标记 → 判定为人机验证")
    func detectsCaptcha() {
        let body = "<script src=\"https://www.google.com/g-recaptcha/api.js\"></script>"
        let hint = ChallengeDetector.detect(statusCode: 403, body: body, contentType: "text/html")
        #expect(hint?.kind == .captcha)
    }

    @Test("200 的正文里出现 cloudflare 不算 —— 页脚版权声明里就有这个词")
    func ignoresOrdinaryPagesWithBrandNames() {
        let body = "<footer>Powered by Cloudflare</footer>"
        #expect(ChallengeDetector.detect(statusCode: 200, body: body, contentType: "text/html") == nil)
    }

    @Test("非 HTML 响应一律不判（图片 / JSON 里出现这些词不算）")
    func ignoresNonHTML() {
        let body = #"{"error":"captcha required"}"#
        #expect(ChallengeDetector.detect(statusCode: 403, body: body, contentType: "application/json") == nil)
        #expect(ChallengeDetector.detect(statusCode: 503, body: "cloudflare", contentType: "image/png") == nil)
    }

    @Test("没有标记的普通错误页不判（避免把 500 都当成验证）")
    func ignoresPlainErrorPages() {
        let body = "<html><body>500 Internal Server Error</body></html>"
        #expect(ChallengeDetector.detect(statusCode: 503, body: body, contentType: "text/html") == nil)
    }

    @Test("空正文不判")
    func ignoresEmptyBody() {
        #expect(ChallengeDetector.detect(statusCode: 503, body: "", contentType: "text/html") == nil)
        #expect(ChallengeDetector.detect(statusCode: 503, body: nil, contentType: "text/html") == nil)
    }

    @Test("同时命中多个厂商标记时优先报 Cloudflare（更具体）")
    func prefersCloudflareMarker() {
        let body = "<html>checking your browser g-recaptcha</html>"
        #expect(ChallengeDetector.detect(statusCode: 503, body: body, contentType: "text/html")?.kind == .cloudflare)
    }

    @Test("缺省的 Content-Type 按 HTML 处理（很多服务器不带它）")
    func treatsMissingContentTypeAsHTML() {
        let body = "<html>checking your browser</html>"
        #expect(ChallengeDetector.detect(statusCode: 503, body: body)?.kind == .cloudflare)
    }

    @Test("从错误文案里嗅探：认厂商名与状态码，不认「验证」这类泛词")
    func detectsFromMessage() {
        #expect(ChallengeDetector.detect(inMessage: "服务器返回 HTTP 503")?.kind == .generic)
        #expect(ChallengeDetector.detect(inMessage: "Cloudflare 拦截")?.kind == .cloudflare)
        #expect(ChallengeDetector.detect(inMessage: "需要 captcha")?.kind == .captcha)
        // 「验证」更可能是登录失效而不是人机校验，不判
        #expect(ChallengeDetector.detect(inMessage: "登录已失效，请验证账号") == nil)
        #expect(ChallengeDetector.detect(inMessage: "网络不可用") == nil)
    }

    @Test("每种验证的标识稳定（展示名已移到 App 层，见 Localization+Names）")
    func kindsHaveStableIdentifiers() {
        // 这些 rawValue 会写进诊断日志，改动会让历史日志对不上，因此钉死。
        #expect(ChallengeKind.cloudflare.rawValue == "cloudflare")
        #expect(ChallengeKind.captcha.rawValue == "captcha")
        #expect(ChallengeKind.generic.rawValue == "generic")
        #expect(ChallengeKind.allCases.count == 3)
    }
}
