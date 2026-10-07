//
//  CloudClientTests.swift
//  MangaTranslaterTests
//
//  云服务客户端与额度计算：
//  - 请求形状（路径、方法、鉴权头）与「/translate 只发三个字段」的铁律；
//  - 错误语义映射（401 未登录、402 额度用尽、429 限流、坏 JSON）；
//  - 邮箱校验与规范化；
//  - 额度重置时刻（东八区自然日）与剩余量表达。
//
//  全部离线：传输层是脚本化的 `StubTransport`，不需要真的服务器。
//

import Foundation
import Testing
import AppCore
import ComicNet
@testable import MangaTranslater

// MARK: - 夹具

/// 云服务测试共用夹具（多个测试文件共用，因此不是 fileprivate）。
enum CloudFixture {
    static let baseURL = "https://cloud.example.com"

    static func client(_ outcomes: [StubTransport.Outcome]) -> (CloudServiceClient, StubTransport) {
        let transport = StubTransport(outcomes: outcomes)
        return (CloudServiceClient(baseURL: baseURL, transport: transport), transport)
    }

    static func json(_ object: Any, statusCode: Int = 200) -> StubTransport.Outcome {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .success(data: data, statusCode: statusCode, headers: ["Content-Type": "application/json"])
    }

    static func raw(_ text: String, statusCode: Int) -> StubTransport.Outcome {
        .success(data: Data(text.utf8), statusCode: statusCode, headers: [:])
    }

    static func accountObject(
        remaining: Int = 8,
        plan: String = "free",
        entitlementExpiresAt: Int? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": "acc-1",
            "email": "reader@example.com",
            "plan": plan,
            "dailyLimit": 10,
            "usedToday": 10 - remaining,
            "remainingToday": remaining,
            "quotaResetAt": 1_800_000_000,
        ]
        if let entitlementExpiresAt {
            object["entitlementExpiresAt"] = entitlementExpiresAt
        }
        return object
    }

    static func account(
        remaining: Int = 8,
        plan: CloudPlan = .free,
        entitlementExpiresAt: Int? = nil
    ) -> CloudAccount {
        CloudAccount(
            id: "acc-1",
            email: "reader@example.com",
            plan: plan,
            entitlementExpiresAt: entitlementExpiresAt,
            dailyLimit: 10,
            usedToday: max(0, 10 - remaining),
            remainingToday: remaining,
            quotaResetAt: 1_800_000_000
        )
    }

    static func session(remaining: Int = 8, plan: CloudPlan = .free) -> CloudSession {
        CloudSession(
            token: "token-abc",
            expiresAt: 4_000_000_000,
            account: account(
                remaining: remaining,
                plan: plan,
                entitlementExpiresAt: plan == .pro ? 4_000_000_000 : nil
            )
        )
    }
}

// MARK: - 客户端

@Suite("云服务客户端")
struct CloudClientTests {

    // MARK: 发码

    @Test("发码请求打在正确路径上，且邮箱被规范化")
    func sendCodeSendsNormalizedEmail() async throws {
        let (client, transport) = CloudFixture.client([CloudFixture.json(["ok": true, "expiresInSeconds": 600])])
        let expires = try await client.sendLoginCode(email: "  Reader@Example.COM ")

        #expect(expires == 600)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://cloud.example.com/auth/email/send")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["email"] as? String == "reader@example.com")
        #expect(object.count == 1)
    }

    @Test("邮箱不合法时本地就拦下，不发请求")
    func sendCodeRejectsInvalidEmail() async {
        let (client, transport) = CloudFixture.client([CloudFixture.json(["ok": true, "expiresInSeconds": 600])])
        await expectThrowsAsync(CloudError.invalidEmail) {
            _ = try await client.sendLoginCode(email: "not-an-email")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("验证码为空时不发请求")
    func verifyRejectsEmptyCode() async {
        let (client, transport) = CloudFixture.client([CloudFixture.json([:])])
        await expectThrowsAsync(CloudError.invalidCode) {
            _ = try await client.verifyLoginCode(email: "reader@example.com", code: "   ")
        }
        #expect(transport.requestCount == 0)
    }

    // MARK: 登录

    @Test("换令牌：解析会话与账号")
    func verifyParsesSession() async throws {
        let (client, transport) = CloudFixture.client([
            CloudFixture.json([
                "token": "token-xyz",
                "expiresAt": 1_900_000_000,
                "account": CloudFixture.accountObject(),
            ])
        ])
        let session = try await client.verifyLoginCode(email: "reader@example.com", code: "123456")

        #expect(session.token == "token-xyz")
        #expect(session.account.remainingToday == 8)
        #expect(session.account.email == "reader@example.com")
        #expect(!session.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(session.isExpired(now: Date(timeIntervalSince1970: 2_000_000_000)))
        #expect(transport.requests.first?.url?.absoluteString == "https://cloud.example.com/auth/email/verify")
    }

    @Test("验证码错误 → invalidCode")
    func verifyMapsInvalidCode() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.raw(#"{"error":"invalid_code","message":"bad code"}"#, statusCode: 400)
        ])
        await expectThrowsAsync(CloudError.invalidCode) {
            _ = try await client.verifyLoginCode(email: "reader@example.com", code: "000000")
        }
    }

    // MARK: 账号

    @Test("查账号带上 Bearer 令牌")
    func meSendsBearerToken() async throws {
        let (client, transport) = CloudFixture.client([CloudFixture.json(CloudFixture.accountObject(remaining: 3))])
        let account = try await client.me(token: "token-abc")

        #expect(account.remainingToday == 3)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://cloud.example.com/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-abc")
    }

    @Test("401 → unauthorized")
    func meMapsUnauthorized() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.raw(#"{"error":"unauthorized","message":"expired"}"#, statusCode: 401)
        ])
        await expectThrowsAsync(CloudError.unauthorized) {
            _ = try await client.me(token: "stale")
        }
    }

    // MARK: 注销账号

    @Test("注销账号：打到 /auth/delete，带 Bearer 令牌，请求体只有 email")
    func deleteAccountRequestShape() async throws {
        let (client, transport) = CloudFixture.client([
            CloudFixture.json(["ok": true, "deleted": true])
        ])
        try await client.deleteAccount(email: "reader@example.com", token: "token-abc")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://cloud.example.com/auth/delete")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-abc")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["email": "reader@example.com"])
    }

    @Test("注销账号：400 email_mismatch → emailMismatch（不当成通用服务端错误）")
    func deleteAccountMapsEmailMismatch() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.json(["error": "email_mismatch", "message": "nope"], statusCode: 400)
        ])
        await expectThrowsAsync(CloudError.emailMismatch) {
            try await client.deleteAccount(email: "other@example.com", token: "token-abc")
        }
    }

    @Test("注销账号：401 → unauthorized（界面据此退回未登录）")
    func deleteAccountMapsUnauthorized() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.json(["error": "unauthorized"], statusCode: 401)
        ])
        await expectThrowsAsync(CloudError.unauthorized) {
            try await client.deleteAccount(email: "reader@example.com", token: "stale")
        }
    }

    // MARK: 翻译（铁律）

    @Test("翻译请求体只含 lines / source / target 三个字段")
    func translateBodyHasExactlyThreeFields() async throws {
        let (client, transport) = CloudFixture.client([
            CloudFixture.json(["lines": ["你好", "世界"], "remainingToday": 7])
        ])
        let result = try await client.translate(
            lines: ["こんにちは", "世界"],
            source: .japanese,
            target: .simplifiedChinese,
            token: "token-abc"
        )

        #expect(result.lines == ["你好", "世界"])
        #expect(result.remainingToday == 7)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://cloud.example.com/translate")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["lines", "source", "target"])
        #expect(object["source"] as? String == "ja")
        #expect(object["target"] as? String == "zh-Hans")
        #expect((object["lines"] as? [String])?.count == 2)
        // 服务端只应收到文字，不该有图片、URL 之类的额外字段
        let serialized = String(decoding: body, as: UTF8.self)
        #expect(!serialized.contains("http"))
    }

    @Test("额度用尽 → quotaExceeded（带剩余页数）")
    func translateMapsQuotaExceeded() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.raw(
                #"{"error":"quota_exceeded","message":"no quota","remainingToday":0}"#,
                statusCode: 402
            )
        ])
        await expectThrowsAsync(CloudError.quotaExceeded(remaining: 0)) {
            _ = try await client.translate(
                lines: ["a"],
                source: .auto,
                target: .english,
                token: "token-abc"
            )
        }
    }

    @Test("订阅都不满足 → subscriptionRequired")
    func translateMapsSubscriptionRequired() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.raw(#"{"error":"subscription_required","message":"no plan"}"#, statusCode: 402)
        ])
        await expectThrowsAsync(CloudError.subscriptionRequired) {
            _ = try await client.translate(
                lines: ["a"],
                source: .auto,
                target: .english,
                token: "token-abc"
            )
        }
    }

    @Test("条数不符由翻译层拒绝，客户端原样透传")
    func translatePassesThroughMismatch() async throws {
        // 客户端只做「结构解析 + 语义分类」，它只能抛 CloudError；
        // 「长度必须与输入一致」是翻译层的契约（TranslationError.countMismatch），
        // 两层各抛一种错会让界面文案不一致，因此这里只断言透传。
        let (client, _) = CloudFixture.client([
            CloudFixture.json(["lines": ["只有一条"], "remainingToday": 5])
        ])
        let result = try await client.translate(
            lines: ["a", "b"],
            source: .auto,
            target: .english,
            token: "token-abc"
        )
        #expect(result.lines == ["只有一条"])
        #expect(result.remainingToday == 5)
    }

    @Test("限流 → rateLimited（用服务端给的等待秒数）")
    func mapsRateLimited() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.raw(
                #"{"error":"rate_limited","message":"slow down","retryAfterSeconds":42}"#,
                statusCode: 429
            )
        ])
        await expectThrowsAsync(CloudError.rateLimited(retryAfterSeconds: 42)) {
            _ = try await client.sendLoginCode(email: "reader@example.com")
        }
    }

    @Test("响应不是 JSON → badResponse")
    func mapsBadResponse() async {
        let (client, _) = CloudFixture.client([CloudFixture.raw("<html>502</html>", statusCode: 200)])
        await expectThrowsAsync(CloudError.badResponse) {
            _ = try await client.me(token: "token-abc")
        }
    }

    @Test("其它 5xx → server(code:message:)")
    func mapsServerError() async {
        let (client, _) = CloudFixture.client([
            CloudFixture.raw(#"{"error":"boom","message":"internal"}"#, statusCode: 500)
        ])
        await expectThrowsAsync(CloudError.server(code: "boom", message: "internal")) {
            _ = try await client.sendLoginCode(email: "reader@example.com")
        }
    }

    @Test("服务地址非法 → missingBaseURL，且不发请求")
    func rejectsInvalidBaseURL() async {
        let transport = StubTransport(data: Data())
        let client = CloudServiceClient(baseURL: "   ", transport: transport)
        await expectThrowsAsync(CloudError.missingBaseURL) {
            _ = try await client.sendLoginCode(email: "reader@example.com")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("结尾斜杠不会拼出双斜杠")
    func normalizesTrailingSlash() async throws {
        let transport = StubTransport(outcomes: [CloudFixture.json(CloudFixture.accountObject())])
        let client = CloudServiceClient(baseURL: "https://cloud.example.com/", transport: transport)
        _ = try await client.me(token: "t")
        #expect(transport.requests.first?.url?.absoluteString == "https://cloud.example.com/me")
        #expect(CloudServiceClient.normalizeBaseURL("https://a.b///") == "https://a.b")
        #expect(CloudServiceClient.normalizeBaseURL("  https://a.b/v1/  ") == "https://a.b/v1")
    }

    // MARK: 错误到翻译错误的映射

    @Test("云错误映射到翻译错误语义")
    func cloudErrorMapsToTranslationError() {
        #expect(CloudError.unauthorized.asTranslationError == .notSignedIn)
        #expect(CloudError.quotaExceeded(remaining: 2).asTranslationError == .quotaExceeded(remaining: 2))
        #expect(CloudError.subscriptionRequired.asTranslationError == .subscriptionRequired)
        #expect(CloudError.quotaExceeded(remaining: 0).isQuotaRelated)
        #expect(CloudError.subscriptionRequired.isQuotaRelated)
        #expect(!CloudError.unauthorized.isQuotaRelated)
    }
}

// MARK: - 输入校验

@Suite("云服务输入校验")
struct CloudValidationTests {

    @Test("邮箱规范化与校验", arguments: [
        ("Reader@Example.com", true),
        ("  a@b.co  ", true),
        ("a.b+tag@sub.example.com", true),
        ("not-an-email", false),
        ("a@b", false),
        ("a b@example.com", false),
        ("@example.com", false),
        ("", false),
    ])
    func validatesEmails(value: String, expected: Bool) {
        #expect(ModelValidation.isValidEmail(value) == expected)
    }

    @Test("邮箱规范化会去掉空白并转小写")
    func normalizesEmail() {
        #expect(ModelValidation.normalizeEmail("  Reader@Example.COM ") == "reader@example.com")
    }

    @Test("邮箱脱敏只留首字母与域名")
    func masksEmail() {
        #expect(CloudAccountModel.mask("reader@example.com") == "r***@example.com")
        #expect(CloudAccountModel.mask("a@b.co") == "a***@b.co")
        #expect(CloudAccountModel.mask("no-at-sign") == "no-at-sign")
    }
}

// MARK: - 额度策略

@Suite("额度策略")
struct QuotaPolicyTests {

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("重置时刻是东八区的次日零点")
    func nextResetIsShanghaiMidnight() {
        // 北京时间 2026-10-07 00:30 → 下一次重置是 2026-10-08 00:00（UTC 为 10-07 16:00）
        let now = Self.date("2026-10-06T16:30:00Z")
        let reset = QuotaPolicy.nextReset(after: now)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let text = formatter.string(from: reset)
        #expect(text.hasPrefix("2026-10-07T16:00:00"))
    }

    @Test("UTC 日界与北京日界不同：UTC 深夜仍算北京的同一天之后")
    func nextResetUsesQuotaCalendarNotUTC() {
        // UTC 2026-10-06 23:30 = 北京 10-07 07:30 → 重置应为北京 10-08 00:00 = UTC 10-07 16:00
        let now = Self.date("2026-10-06T23:30:00Z")
        let reset = QuotaPolicy.nextReset(after: now)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        #expect(formatter.string(from: reset).hasPrefix("2026-10-07T16:00:00"))
    }

    @Test("重置时刻严格晚于当前时刻")
    func resetIsInTheFuture() {
        let now = Date()
        #expect(QuotaPolicy.nextReset(after: now) > now)
    }

    @Test("剩余比例会被钳制到 0...1", arguments: [
        (10, 10, 1.0),
        (5, 10, 0.5),
        (0, 10, 0.0),
        (-3, 10, 0.0),
        (99, 10, 1.0),
        (5, 0, 0.0),
    ])
    func remainingFraction(remaining: Int, limit: Int, expected: Double) {
        #expect(abs(QuotaPolicy.remainingFraction(remaining: remaining, limit: limit) - expected) < 0.0001)
    }

    @Test("额度用尽判定")
    func exhaustion() {
        #expect(QuotaPolicy.isExhausted(remaining: 0))
        #expect(QuotaPolicy.isExhausted(remaining: -1))
        #expect(!QuotaPolicy.isExhausted(remaining: 1))
    }

    @Test("重置时刻格式化到分钟")
    func resetDescription() {
        // 2026-10-07 16:00 UTC = 次日 00:00 北京 → 文案应为 00:00
        let date = Self.date("2026-10-07T16:00:00Z")
        #expect(QuotaPolicy.resetDescription(for: date) == "00:00")
    }

    @Test("额度摘要：免费 / 用尽 / 订阅三态")
    func summaries() {
        let free = CloudFixture.account(remaining: 4)
        #expect(QuotaPolicy.summary(account: free).contains("4"))

        // 用尽时要给出重置时间；重置时间由服务端快照决定，因此按同一函数算期望值，
        // 避免把「时区/格式」写死在测试里
        let used = CloudFixture.account(remaining: 0)
        let expectedReset = QuotaPolicy.resetDescription(for: used.quotaResetDate)
        #expect(QuotaPolicy.summary(account: used).contains(expectedReset))

        let pro = CloudFixture.account(remaining: 0, plan: .pro, entitlementExpiresAt: 4_000_000_000)
        #expect(QuotaPolicy.summary(account: pro) == L("cloud.quota.unlimited"))
    }

    @Test("订阅档不受免费额度限制")
    func proIsNotLimited() {
        let pro = CloudFixture.account(remaining: 0, plan: .pro, entitlementExpiresAt: 4_000_000_000)
        #expect(pro.isPro)
        #expect(!pro.isQuotaExhausted)
    }
}
