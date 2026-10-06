//
//  CloudAccountTests.swift
//  MangaTranslaterTests
//
//  云服务账号状态机与云端翻译后端：
//  - 发码 / 校验 / 登录 / 退出 / 会话过期（401 自动退回未登录）；
//  - 额度回传（服务端每次翻译带回剩余页数）；
//  - 购买链接带上账号 ID；
//  - 云端翻译后端的错误映射与分块顺序。
//
//  会话存储注入内存实现，**不碰真实钥匙串**。
//

import Foundation
import Testing
import AppCore
import ComicNet
@testable import MangaTranslater

// MARK: - 记录器

/// 记录回调收到的值（跨并发域，用锁保护）。
private final class ValueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var recorded: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var last: Int? { recorded.last }
}

// MARK: - 账号状态机

@Suite("云服务账号")
@MainActor
struct CloudAccountTests {

    private static func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let suiteName = "CloudAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    private static func makeModel(
        settings: AppSettings,
        outcomes: [StubTransport.Outcome],
        session: CloudSession? = nil
    ) -> (CloudAccountModel, StubTransport, InMemoryCloudSessionStore) {
        let transport = StubTransport(outcomes: outcomes)
        let store = InMemoryCloudSessionStore(session: session)
        let model = CloudAccountModel(
            settings: settings,
            transport: transport,
            sessionStore: store,
            session: session
        )
        return (model, transport, store)
    }

    // MARK: 初始状态

    @Test("没有会话时为未登录")
    func startsSignedOut() throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(settings: settings, outcomes: [])
        #expect(!model.isSignedIn)
        #expect(model.account == nil)
        #expect(!model.isBusy)
        #expect(!model.isAwaitingCode)
        #expect(model.quotaSummary == L("cloud.quota.unknown"))
    }

    @Test("已有会话时开局即登录")
    func restoresSession() throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(
            settings: settings,
            outcomes: [],
            session: CloudFixture.session(remaining: 6, plan: .pro)
        )
        #expect(model.isSignedIn)
        #expect(model.account?.remainingToday == 6)
        #expect(model.planName == CloudPlan.pro.displayName)
        #expect(model.maskedEmail == "r***@example.com")
        #expect(model.entitlementDescription != nil)
    }

    @Test("订阅档的额度摘要是「不限量」")
    func proQuotaSummary() throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(
            settings: settings,
            outcomes: [],
            session: CloudFixture.session(remaining: 0, plan: .pro)
        )
        #expect(model.quotaSummary == L("cloud.quota.unlimited"))
    }

    // MARK: 发码

    @Test("邮箱非法时本地拦下，不发请求")
    func sendCodeRejectsBadEmail() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, transport, _) = Self.makeModel(settings: settings, outcomes: [])
        let ok = await model.sendCode(email: "nope")
        #expect(!ok)
        #expect(model.notice != nil)
        #expect(!model.isAwaitingCode)
        #expect(transport.requestCount == 0)
    }

    @Test("发码成功进入「等验证码」状态并提示脱敏邮箱")
    func sendCodeSucceeds() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(
            settings: settings,
            outcomes: [CloudFixture.json(["ok": true, "expiresInSeconds": 600])]
        )
        let ok = await model.sendCode(email: "Reader@Example.com")
        #expect(ok)
        #expect(model.isAwaitingCode)
        #expect(model.pendingEmail == "reader@example.com")
        #expect(model.codeExpiresInSeconds == 600)
        #expect(model.notice?.contains("r***@example.com") == true)
        #expect(!model.isBusy)
    }

    @Test("发码失败时给出服务端错误文案，且不进入等验证码状态")
    func sendCodeFailure() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(
            settings: settings,
            outcomes: [CloudFixture.raw(#"{"error":"bad_gateway","message":"down"}"#, statusCode: 502)]
        )
        let ok = await model.sendCode(email: "reader@example.com")
        #expect(!ok)
        #expect(!model.isAwaitingCode)
        #expect(model.notice != nil)
    }

    // MARK: 校验

    @Test("验证码正确 → 登录并把会话落盘")
    func verifySucceeds() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(
            settings: settings,
            outcomes: [
                CloudFixture.json(["ok": true, "expiresInSeconds": 600]),
                CloudFixture.json([
                    "token": "token-1",
                    "expiresAt": 4_000_000_000,
                    "account": CloudFixture.accountObject(remaining: 9),
                ]),
            ]
        )
        _ = await model.sendCode(email: "reader@example.com")
        let ok = await model.verifyCode("123456")

        #expect(ok)
        #expect(model.isSignedIn)
        #expect(model.account?.remainingToday == 9)
        #expect(!model.isAwaitingCode)
        #expect(store.load()?.token == "token-1")
    }

    @Test("验证码错误 → 保持未登录，提示由服务端文案给出")
    func verifyFails() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(
            settings: settings,
            outcomes: [
                CloudFixture.json(["ok": true, "expiresInSeconds": 600]),
                CloudFixture.raw(#"{"error":"invalid_code","message":"nope"}"#, statusCode: 400),
            ]
        )
        _ = await model.sendCode(email: "reader@example.com")
        let ok = await model.verifyCode("000000")

        #expect(!ok)
        #expect(!model.isSignedIn)
        #expect(model.isAwaitingCode)   // 还停在输码界面，允许重试
        #expect(store.load() == nil)
    }

    @Test("没发过码就想校验 → 直接拒绝")
    func verifyWithoutPendingEmail() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, transport, _) = Self.makeModel(settings: settings, outcomes: [])
        let ok = await model.verifyCode("123456")
        #expect(!ok)
        #expect(transport.requestCount == 0)
    }

    @Test("空验证码不发请求")
    func verifyEmptyCode() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, transport, _) = Self.makeModel(
            settings: settings,
            outcomes: [CloudFixture.json(["ok": true, "expiresInSeconds": 600])]
        )
        _ = await model.sendCode(email: "reader@example.com")
        let before = transport.requestCount
        let ok = await model.verifyCode("   ")
        #expect(!ok)
        #expect(transport.requestCount == before)
    }

    @Test("换邮箱会退出等验证码状态")
    func cancelVerificationResets() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(
            settings: settings,
            outcomes: [CloudFixture.json(["ok": true, "expiresInSeconds": 600])]
        )
        _ = await model.sendCode(email: "reader@example.com")
        model.cancelVerification()
        #expect(!model.isAwaitingCode)
        #expect(model.pendingEmail == nil)
        #expect(model.notice == nil)
    }

    // MARK: 刷新

    @Test("刷新会更新额度并回写会话")
    func refreshUpdatesQuota() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(
            settings: settings,
            outcomes: [CloudFixture.json(CloudFixture.accountObject(remaining: 2))],
            session: CloudFixture.session(remaining: 8)
        )
        await model.refresh()
        #expect(model.account?.remainingToday == 2)
        #expect(store.load()?.account.remainingToday == 2)
        #expect(!model.isBusy)
    }

    @Test("令牌过期（401）→ 自动退回未登录并清掉会话")
    func refreshExpiredSession() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(
            settings: settings,
            outcomes: [CloudFixture.raw(#"{"error":"unauthorized"}"#, statusCode: 401)],
            session: CloudFixture.session()
        )
        await model.refresh()

        #expect(!model.isSignedIn)
        #expect(model.account == nil)
        #expect(store.load() == nil)
        #expect(store.clearCount == 1)
        #expect(model.notice == L("cloud.login.sessionExpired"))
    }

    @Test("未登录时刷新是空操作")
    func refreshWithoutSessionDoesNothing() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, transport, _) = Self.makeModel(settings: settings, outcomes: [])
        await model.refresh()
        #expect(transport.requestCount == 0)
    }

    // MARK: 退出与额度回传

    @Test("退出登录只清本机会话")
    func signOutClearsSession() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(
            settings: settings,
            outcomes: [],
            session: CloudFixture.session()
        )
        model.signOut()
        #expect(!model.isSignedIn)
        #expect(store.load() == nil)
        #expect(model.notice == L("cloud.login.signedOut"))
    }

    @Test("额度回传会更新快照并按上限钳制")
    func applyRemainingClamps() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(
            settings: settings,
            outcomes: [],
            session: CloudFixture.session(remaining: 5)
        )

        model.applyRemaining(1)
        #expect(model.account?.remainingToday == 1)
        #expect(model.account?.usedToday == 9)

        // 服务端给的值超出上限时按上限收，避免界面出现「剩余 999 / 10」
        model.applyRemaining(999)
        #expect(model.account?.remainingToday == 10)
        #expect(model.account?.usedToday == 0)

        model.applyRemaining(-4)
        #expect(model.account?.remainingToday == 0)
        #expect(store.load()?.account.remainingToday == 0)
    }

    @Test("未登录时额度回传是空操作")
    func applyRemainingWithoutAccountDoesNothing() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, store) = Self.makeModel(settings: settings, outcomes: [])
        model.applyRemaining(3)
        #expect(model.account == nil)
        #expect(store.load() == nil)
    }

    // MARK: 购买链接

    @Test("购买链接带上账号 ID")
    func purchaseURLCarriesAccountID() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(
            settings: settings,
            outcomes: [],
            session: CloudFixture.session()
        )
        let url = try #require(model.purchaseURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let item = components.queryItems?.first { $0.name == "custom[user_id]" }
        #expect(item?.value == "acc-1")
        #expect(components.path == "/upgrade")
    }

    @Test("未登录时购买链接不带账号参数")
    func purchaseURLWithoutAccount() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(settings: settings, outcomes: [])
        let url = try #require(model.purchaseURL)
        #expect(!url.absoluteString.contains("user_id"))
    }

    @Test("清提示")
    func clearsNotice() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = Self.makeModel(settings: settings, outcomes: [])
        _ = await model.sendCode(email: "bad")
        #expect(model.notice != nil)
        model.clearNotice()
        #expect(model.notice == nil)
    }
}

// MARK: - 云端翻译后端

@Suite("云端翻译后端")
struct CloudTranslationServiceTests {

    private static func service(
        outcomes: [StubTransport.Outcome],
        chunkSize: Int = 40,
        recorder: ValueRecorder? = nil
    ) -> CloudTranslationService {
        let transport = StubTransport(outcomes: outcomes)
        let client = CloudServiceClient(baseURL: CloudFixture.baseURL, transport: transport)
        return CloudTranslationService(
            client: client,
            token: "token-abc",
            chunkSize: chunkSize,
            onRemaining: { remaining in recorder?.record(remaining) }
        )
    }

    @Test("空输入直接返回，不发请求")
    func emptyInput() async throws {
        let transport = StubTransport(data: Data())
        let client = CloudServiceClient(baseURL: CloudFixture.baseURL, transport: transport)
        let service = CloudTranslationService(client: client, token: "t")
        let out = try await service.translate([], source: .auto, target: .english)
        #expect(out.isEmpty)
        #expect(transport.requestCount == 0)
    }

    @Test("正常翻译并回传剩余额度")
    func translatesAndReportsQuota() async throws {
        let recorder = ValueRecorder()
        let service = Self.service(
            outcomes: [CloudFixture.json(["lines": ["你好"], "remainingToday": 7])],
            recorder: recorder
        )
        let out = try await service.translate(["こんにちは"], source: .japanese, target: .simplifiedChinese)
        #expect(out == ["你好"])
        #expect(recorder.last == 7)
    }

    @Test("分块后顺序不变，且每块都回传额度")
    func chunksPreserveOrder() async throws {
        let recorder = ValueRecorder()
        let service = Self.service(
            outcomes: [
                CloudFixture.json(["lines": ["a0", "a1"], "remainingToday": 8]),
                CloudFixture.json(["lines": ["a2"], "remainingToday": 7]),
            ],
            chunkSize: 2,
            recorder: recorder
        )
        let out = try await service.translate(["t0", "t1", "t2"], source: .auto, target: .english)
        #expect(out == ["a0", "a1", "a2"])
        #expect(recorder.recorded == [8, 7])
    }

    @Test("额度用尽映射成配额类翻译错误（界面据此给升级入口）")
    func mapsQuotaExceeded() async {
        let service = Self.service(outcomes: [
            CloudFixture.raw(
                #"{"error":"quota_exceeded","message":"no quota","remainingToday":0}"#,
                statusCode: 402
            )
        ])
        await expectThrowsAsync(TranslationError.quotaExceeded(remaining: 0)) {
            _ = try await service.translate(["a"], source: .auto, target: .english)
        }
    }

    @Test("令牌失效映射成「未登录」")
    func mapsUnauthorized() async {
        let service = Self.service(outcomes: [
            CloudFixture.raw(#"{"error":"unauthorized"}"#, statusCode: 401)
        ])
        await expectThrowsAsync(TranslationError.notSignedIn) {
            _ = try await service.translate(["a"], source: .auto, target: .english)
        }
    }

    @Test("条数不符会报错而不是错位")
    func rejectsCountMismatch() async {
        let service = Self.service(outcomes: [
            CloudFixture.json(["lines": ["少了一条"], "remainingToday": 9])
        ])
        await expectThrowsAsync(TranslationError.countMismatch(expected: 2, got: 1)) {
            _ = try await service.translate(["a", "b"], source: .auto, target: .english)
        }
    }

    @Test("网络失败映射成云端错误")
    func mapsTransportFailure() async {
        let transport = StubTransport(outcomes: [.failure(.offline)])
        let client = CloudServiceClient(baseURL: CloudFixture.baseURL, transport: transport)
        let service = CloudTranslationService(client: client, token: "t")
        do {
            _ = try await service.translate(["a"], source: .auto, target: .english)
            Issue.record("应当抛错")
        } catch let error as TranslationError {
            if case .cloud = error {
                // 期望
            } else {
                Issue.record("期望云端错误，实际 \(error)")
            }
        } catch {
            Issue.record("期望 TranslationError，实际 \(error)")
        }
    }
}
