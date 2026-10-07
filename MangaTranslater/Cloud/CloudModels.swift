//
//  CloudModels.swift
//  MangaTranslater
//
//  云服务的数据模型与错误。
//
//  与 `docs/cloud-api.md` 的线格式一一对应。两个刻意的选择：
//
//  1. **时间一律用 epoch 秒（Int）**，不用 ISO8601 字符串。
//     客户端与服务端各自有时区与格式化差异，字符串时间一旦有一侧写错格式，
//     报出来的错是「解析失败」而不是「时间不对」——很难查。整数秒没有这种歧义。
//  2. **字段名用 camelCase**，不引入 `convertFromSnakeCase`。
//     编解码策略是隐式的：忘了一次就整片字段读不出来，而且写测试时
//     很容易连测试带实现一起写错（测试也用了同一个策略）。
//     显式一致的命名让「客户端与服务端到底约定了什么」在两边都能直接看出来。
//

import Foundation
import AppCore

// MARK: - 订阅档位

enum CloudPlan: String, Codable, Sendable, CaseIterable {
    case free
    case pro

    var displayName: String {
        switch self {
        case .free: return L("cloud.plan.free")
        case .pro: return L("cloud.plan.pro")
        }
    }
}

// MARK: - 账号状态

/// 账号与额度快照。服务端是唯一事实来源；客户端只做展示。
struct CloudAccount: Codable, Equatable, Sendable {
    let id: String
    let email: String
    /// 服务端已按有效期折算过的档位。
    let plan: CloudPlan
    /// 订阅到期时刻（epoch 秒）。免费档为 nil。
    let entitlementExpiresAt: Int?
    /// 每日免费额度上限（页）。
    let dailyLimit: Int
    /// 今天已用页数。
    let usedToday: Int
    /// 今天剩余页数。
    let remainingToday: Int
    /// 今日额度重置时刻（epoch 秒）。
    let quotaResetAt: Int

    init(
        id: String,
        email: String,
        plan: CloudPlan = .free,
        entitlementExpiresAt: Int? = nil,
        dailyLimit: Int = QuotaPolicy.freeDailyLimit,
        usedToday: Int = 0,
        remainingToday: Int = QuotaPolicy.freeDailyLimit,
        quotaResetAt: Int = QuotaPolicy.defaultResetEpoch()
    ) {
        self.id = id
        self.email = email
        self.plan = plan
        self.entitlementExpiresAt = entitlementExpiresAt
        self.dailyLimit = dailyLimit
        self.usedToday = usedToday
        self.remainingToday = remainingToday
        self.quotaResetAt = quotaResetAt
    }

    /// 用服务端刚回传的剩余页数更新快照。
    ///
    /// 已用页数按「上限 − 剩余」反推，而不是各自独立存储：
    /// 两个字段独立更新迟早会出现「剩余 8、已用 5、上限 10」这种自相矛盾的状态。
    func applying(remainingToday: Int) -> CloudAccount {
        let clamped = min(max(0, remainingToday), max(0, dailyLimit))
        return CloudAccount(
            id: id,
            email: email,
            plan: plan,
            entitlementExpiresAt: entitlementExpiresAt,
            dailyLimit: dailyLimit,
            usedToday: max(0, dailyLimit - clamped),
            remainingToday: clamped,
            quotaResetAt: quotaResetAt
        )
    }

    var entitlementExpiresAtDate: Date? {
        entitlementExpiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var quotaResetDate: Date {
        Date(timeIntervalSince1970: TimeInterval(quotaResetAt))
    }

    /// 是否处在有效订阅档。
    var isPro: Bool { plan == .pro }

    /// 免费额度是否已用尽。
    var isQuotaExhausted: Bool { !isPro && remainingToday <= 0 }
}

// MARK: - 登录会话

/// 登录会话：令牌 + 到期时刻 + 账号快照。
///
/// 整体作为一个 JSON 存进 Keychain（见 `CloudSessionStore`）：
/// 令牌与账号信息本来就是一起用的，拆开存只会多一处可能不一致的状态。
struct CloudSession: Codable, Equatable, Sendable {
    let token: String
    /// 令牌到期时刻（epoch 秒）。
    let expiresAt: Int
    let account: CloudAccount

    var expiresAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }

    func isExpired(now: Date = Date()) -> Bool {
        Date(timeIntervalSince1970: TimeInterval(expiresAt)) <= now
    }

    /// 距到期还有多久（秒）。已过期为 0。
    func secondsUntilExpiry(now: Date = Date()) -> Int {
        max(0, expiresAt - Int(now.timeIntervalSince1970))
    }
}

// MARK: - 翻译结果

/// 一次云端翻译的结果：译文 + 额度变化。
struct CloudTranslationResult: Equatable, Sendable {
    let lines: [String]
    /// 本次之后今天的剩余页数。
    let remainingToday: Int
}

// MARK: - 错误

enum CloudError: LocalizedError, Equatable {
    /// 邮箱格式不合法（客户端先拦一道，省一次往返）。
    case invalidEmail
    /// 验证码错误或已过期。
    case invalidCode
    /// 注销账号时输入的确认邮箱与账号不符。
    case emailMismatch
    /// 请求过于频繁（含服务端给出的建议等待秒数）。
    case rateLimited(retryAfterSeconds: Int)
    /// 未登录或令牌过期。
    case unauthorized
    /// 免费额度用尽。
    case quotaExceeded(remaining: Int)
    /// 额度与订阅都不满足。
    case subscriptionRequired
    /// 服务端业务错误（保留原始 code 便于排查）。
    case server(code: String, message: String)
    /// 响应格式无法解析。
    case badResponse
    /// 传输层失败。
    case transport(String)
    /// 服务地址未配置或非法。
    case missingBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return L("cloud.error.invalidEmail")
        case .invalidCode:
            return L("cloud.error.invalidCode")
        case .emailMismatch:
            return L("cloud.error.emailMismatch")
        case let .rateLimited(seconds):
            return String(format: L("cloud.error.rateLimited"), seconds)
        case .unauthorized:
            return L("cloud.error.unauthorized")
        case let .quotaExceeded(remaining):
            return String(format: L("cloud.error.quotaExceeded"), remaining)
        case .subscriptionRequired:
            return L("cloud.error.subscriptionRequired")
        case let .server(code, message):
            return String(format: L("cloud.error.server"), "\(code) · \(message)")
        case .badResponse:
            return L("cloud.error.badResponse")
        case let .transport(reason):
            return String(format: L("cloud.error.transport"), reason)
        case .missingBaseURL:
            return L("cloud.error.missingBaseURL")
        }
    }

    /// 映射成翻译层的错误，供翻译编排器统一呈现。
    var asTranslationError: TranslationError {
        switch self {
        case .unauthorized:
            return .notSignedIn
        case let .quotaExceeded(remaining):
            return .quotaExceeded(remaining: remaining)
        case .subscriptionRequired:
            return .subscriptionRequired
        default:
            return .cloud(errorDescription ?? "")
        }
    }

    /// 是不是「额度类」问题（界面据此给升级入口）。
    var isQuotaRelated: Bool {
        switch self {
        case .quotaExceeded, .subscriptionRequired: return true
        default: return false
        }
    }
}

// MARK: - 线格式（仅用于编解码，不对界面暴露）

/// 服务端的错误信封：`{"error": "code", "message": "..."}`。
struct CloudErrorEnvelope: Codable {
    let error: String
    let message: String?
    /// 额度不足时服务端会带上剩余页数。
    let remainingToday: Int?
    /// 限流时服务端会带上建议等待秒数。
    let retryAfterSeconds: Int?
}

/// `POST /auth/email/send` 的响应。
struct CloudSendCodeResponse: Codable {
    let ok: Bool
    let expiresInSeconds: Int
}

/// `POST /translate` 的请求体。
///
/// **铁律**（《开发手册》7.1）：只带 `lines` / `source` / `target` 三个字段。
/// 不收图片、不收 URL、不留存文本——这是数据切割的落点，
/// 因此这里刻意用显式 CodingKeys 把「只发这三个」写死，
/// 而不是「顺手把整个字典编码出去」。
struct CloudTranslateRequest: Encodable {
    let lines: [String]
    let source: String
    let target: String

    enum CodingKeys: String, CodingKey {
        case lines, source, target
    }
}

/// `POST /translate` 的响应。
struct CloudTranslateResponse: Codable {
    let lines: [String]
    let remainingToday: Int
}

/// `POST /auth/email/verify` 的响应。
struct CloudVerifyResponse: Codable {
    let token: String
    let expiresAt: Int
    let account: CloudAccount
}
