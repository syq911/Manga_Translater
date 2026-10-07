//
//  CloudAccountModel.swift
//  MangaTranslater
//
//  云服务账号状态机：发码 → 验证 → 登录 → 额度刷新 / 退出。
//
//  界面（`CloudAccountView`）只读这里的 `@Observable` 状态、只调这里的方法，
//  网络调用与状态迁移全在这一层，于是「邮箱验证码登录」的边界条件
//  （邮箱非法、验证码错、令牌过期、额度耗尽、断网）可以逐条单测。
//
//  三条约定：
//  1. **令牌过期是「退出登录」而不是「报错」**：服务端返回 401 说明这个会话
//     已经不可用了，继续留着它只会让每次请求都失败一次。清掉会话、回到未登录态，
//     用户重新登录即可——而重新登录就是「恢复订阅」的同一件事。
//  2. **不猜额度**：剩余页数只信服务端。本地只做「服务端回传后立即更新」。
//  3. **入口不止设置页**：阅读器额度用尽时也会走到这里（`applyRemaining`），
//     因此额度更新是一个独立方法，不绑在某个页面的生命周期上。
//

import Foundation
import Observation
import AppCore
import ComicNet

@MainActor
@Observable
final class CloudAccountModel {

    /// 正在进行中的动作（界面据此禁用按钮 / 显示转圈）。
    enum Step: Equatable, Sendable {
        case idle
        case sendingCode
        case verifying
        case refreshing
        case deleting
    }

    private(set) var session: CloudSession?
    private(set) var account: CloudAccount?
    private(set) var step: Step = .idle
    /// 一次性提示（成功/失败的一句话），界面显示后由 `clearNotice()` 清掉。
    private(set) var notice: String?
    /// 已发出验证码的邮箱：非 nil 时界面显示验证码输入框。
    private(set) var pendingEmail: String?
    /// 验证码有效期（秒），来自服务端。
    private(set) var codeExpiresInSeconds: Int?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transport: HTTPTransporting
    /// 测试可注入一个内存会话存储，避免污染真实钥匙串。
    @ObservationIgnored private let sessionStore: CloudSessionStoring

    init(
        settings: AppSettings,
        transport: HTTPTransporting = URLSessionTransport(timeoutSeconds: 30),
        sessionStore: CloudSessionStoring = CloudSessionStore.live(),
        session: CloudSession? = nil
    ) {
        self.settings = settings
        self.transport = transport
        self.sessionStore = sessionStore
        let restored = session ?? sessionStore.load()
        self.session = restored
        self.account = restored?.account
    }

    // MARK: 派生状态

    var isSignedIn: Bool { session != nil }

    var isBusy: Bool { step != .idle }

    /// 是否等待输入验证码。
    var isAwaitingCode: Bool { pendingEmail != nil }

    var maskedEmail: String {
        guard let email = account?.email else { return "" }
        return CloudAccountModel.mask(email)
    }

    /// 额度摘要文案（免费剩余 / 订阅不限量）。
    var quotaSummary: String {
        guard let account else { return L("cloud.quota.unknown") }
        return QuotaPolicy.summary(account: account)
    }

    var planName: String { account?.plan.displayName ?? CloudPlan.free.displayName }

    /// 订阅到期日文案；免费档返回 nil。
    var entitlementDescription: String? {
        guard let date = account?.entitlementExpiresAtDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// 客户端算出的额度重置时刻（服务端快照里没有时用它兜底显示）。
    var resetDescription: String {
        let date = account?.quotaResetDate ?? QuotaPolicy.nextReset(after: Date())
        return QuotaPolicy.resetDescription(for: date)
    }

    // MARK: 登录

    /// 发验证码。
    /// - Returns: 是否成功。
    @discardableResult
    func sendCode(email: String) async -> Bool {
        let normalized = ModelValidation.normalizeEmail(email)
        guard ModelValidation.isValidEmail(normalized) else {
            notice = CloudError.invalidEmail.errorDescription
            return false
        }
        step = .sendingCode
        defer { step = .idle }
        do {
            let expires = try await client.sendLoginCode(email: normalized)
            pendingEmail = normalized
            codeExpiresInSeconds = expires
            notice = String(
                format: L("cloud.login.codeSent"),
                CloudAccountModel.mask(normalized),
                max(1, expires / 60)
            )
            return true
        } catch {
            notice = CloudAccountModel.message(for: error)
            return false
        }
    }

    /// 校验验证码并登录。
    @discardableResult
    func verifyCode(_ code: String) async -> Bool {
        guard let email = pendingEmail else {
            notice = CloudError.invalidCode.errorDescription
            return false
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = CloudError.invalidCode.errorDescription
            return false
        }
        step = .verifying
        defer { step = .idle }
        do {
            let newSession = try await client.verifyLoginCode(email: email, code: trimmed)
            apply(newSession)
            pendingEmail = nil
            codeExpiresInSeconds = nil
            notice = L("cloud.login.signedIn")
            return true
        } catch {
            notice = CloudAccountModel.message(for: error)
            return false
        }
    }

    /// 放弃这次验证码流程（回到只输邮箱的状态）。
    func cancelVerification() {
        pendingEmail = nil
        codeExpiresInSeconds = nil
        notice = nil
    }

    // MARK: 会话生命周期

    /// 刷新账号与额度。令牌过期（401）时自动退回未登录态。
    func refresh() async {
        guard let current = session else { return }
        step = .refreshing
        defer { step = .idle }
        do {
            let latest = try await client.me(token: current.token)
            let updated = CloudSession(token: current.token, expiresAt: current.expiresAt, account: latest)
            session = updated
            account = latest
            sessionStore.save(updated)
        } catch CloudError.unauthorized {
            // 令牌已失效：清掉本地会话，回到未登录态，让用户重新登录
            signOut(notice: L("cloud.login.sessionExpired"))
        } catch {
            notice = CloudAccountModel.message(for: error)
        }
    }

    /// 注销账号（**服务端删号**，不可撤销）。
    ///
    /// - Parameter email: 用户重新输入的邮箱，必须与当前账号一致；
    ///   这是防「令牌被盗后一键毁号」的二次确认，服务端也会再校验一次。
    /// - Returns: 是否成功。
    @discardableResult
    func deleteAccount(email: String) async -> Bool {
        guard let current = session else {
            notice = CloudError.unauthorized.errorDescription
            return false
        }
        let typed = ModelValidation.normalizeEmail(email)
        let actual = ModelValidation.normalizeEmail(account?.email ?? "")
        guard !typed.isEmpty, typed == actual else {
            // 客户端先拦一道：省一次往返，也避免把「填错了」报成「服务端错误」。
            notice = CloudError.emailMismatch.errorDescription
            return false
        }
        step = .deleting
        defer { step = .idle }
        do {
            try await client.deleteAccount(email: typed, token: current.token)
            // 账号没了，本机会话必须一起清掉：留着它只会让每个请求失败一次。
            sessionStore.clear()
            session = nil
            account = nil
            pendingEmail = nil
            codeExpiresInSeconds = nil
            notice = L("cloud.delete.done")
            return true
        } catch CloudError.unauthorized {
            signOut(notice: L("cloud.login.sessionExpired"))
            return false
        } catch {
            notice = CloudAccountModel.message(for: error)
            return false
        }
    }

    /// 退出登录（只清本机会话，不删账号与订阅）。
    func signOut(notice message: String? = nil) {
        sessionStore.clear()
        session = nil
        account = nil
        pendingEmail = nil
        codeExpiresInSeconds = nil
        notice = message ?? L("cloud.login.signedOut")
    }

    /// 由翻译链路回传的额度更新（服务端每次翻译都会带回剩余页数）。
    func applyRemaining(_ remaining: Int) {
        guard let account else { return }
        let updated = account.applying(remainingToday: remaining)
        self.account = updated
        if let session {
            let refreshed = CloudSession(token: session.token, expiresAt: session.expiresAt, account: updated)
            self.session = refreshed
            sessionStore.save(refreshed)
        }
    }

    func clearNotice() { notice = nil }

    /// 供阅读器额度耗尽横幅调用：跳官网购买页用的地址（带账号 ID）。
    var purchaseURL: URL? {
        var components = URLComponents(string: settings.cloudUpgradeURL)
        var items = components?.queryItems ?? []
        if let accountID = account?.id, !accountID.isEmpty {
            // Lemon Squeezy 会把 checkout 里的 custom 字段原样回传进 webhook，
            // 服务端据此把订阅绑到账号上（《开发手册》7.3）。
            items.append(URLQueryItem(name: "custom[user_id]", value: accountID))
        }
        components?.queryItems = items.isEmpty ? nil : items
        return components?.url ?? URL(string: settings.cloudUpgradeURL)
    }

    // MARK: 内部

    private var client: CloudServiceClient {
        CloudServiceClient(baseURL: settings.cloudServiceBaseURL, transport: transport)
    }

    private func apply(_ newSession: CloudSession) {
        session = newSession
        account = newSession.account
        sessionStore.save(newSession)
    }

    private static func message(for error: Error) -> String {
        if let cloud = error as? CloudError { return cloud.errorDescription ?? "" }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// 邮箱脱敏：`abcd@example.com` → `a***@example.com`。
    ///
    /// 界面上不必完整显示邮箱（旁边就是自己的手机），少显示一点少一分泄露面。
    ///
    /// 标 `nonisolated`：它是**纯字符串函数**，不碰任何 actor 状态。
    /// 不标的话它会继承类的 `@MainActor` 隔离，于是任何非主线程上下文
    /// （比如不隔离的测试用例）都没法调用它——实测就是 `#expect` 宏里报
    /// "call to main actor-isolated static method 'mask' in a synchronous
    /// nonisolated context"。
    nonisolated static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let local = String(email[email.startIndex..<at])
        let domain = String(email[at...])
        guard let first = local.first else { return email }
        return "\(first)***\(domain)"
    }
}
