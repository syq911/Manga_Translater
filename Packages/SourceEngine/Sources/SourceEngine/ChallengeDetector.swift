//
//  ChallengeDetector.swift
//  SourceEngine
//
//  识别「人工验证」页面。
//
//  为什么要单独识别：这类站点（Cloudflare 的「Checking your browser」、
//  reCAPTCHA / hCaptcha 人机校验）对普通请求返回的是 **HTTP 200/403/503 +
//  一页 HTML**，看起来「请求成功但没有内容」。如果不识别，用户看到的是
//  「这个源没有返回任何作品」，而真正的原因是「需要在浏览器里点一下」。
//
//  识别到之后宿主做的事：给一个「打开网页验证」的入口（内嵌网页，
//  用户点完验证，Cookie 由 `CookieHarvest` 交回该源的容器）。
//
//  判定是纯函数，可以脱离网络单测——这里最容易犯的错是
//  「把普通 HTML 也判成验证页」（于是正常站点被要求去点验证）。
//

import Foundation

/// 验证页的种类。
public enum ChallengeKind: String, Equatable, Sendable {
    /// Cloudflare 的浏览器校验（Waiting Room / JS Challenge）。
    case cloudflare
    /// 人机验证（reCAPTCHA / hCaptcha / Turnstile）。
    case captcha
    /// 识别不出具体厂商，但确实是「先验证再访问」的页面。
    case generic

    // 展示名不在这里：本包拿不到 App 目标的 `L()`。
    // 界面上的名称见 App 层 `Localization+Names.swift`（`localizedName`）。
}

/// 一次命中的判定结果。
public struct ChallengeHint: Equatable, Sendable {
    public let kind: ChallengeKind
    /// 命中的标记（写进诊断日志，便于确认判定是否合理）。
    public let marker: String

    public init(kind: ChallengeKind, marker: String) {
        self.kind = kind
        self.marker = marker
    }
}

/// 验证页识别器。
public enum ChallengeDetector {

    /// 需要「先验证」的 HTTP 状态码。
    ///
    /// 只有这几个状态码才值得看正文：200 的普通页面里出现 `cloudflare`
    /// 这个词太常见了（页脚版权声明里就有），照它判定会把正常站点误伤。
    public static let challengeStatusCodes: Set<Int> = [403, 429, 503]

    /// 标记 → 种类。顺序即优先级（更具体的厂商标记排在前面）。
    public static let markers: [(marker: String, kind: ChallengeKind)] = [
        ("cf-chl-", .cloudflare),
        ("cf_chl_", .cloudflare),
        ("__cf_chl", .cloudflare),
        ("challenge-platform", .cloudflare),
        ("just a moment", .cloudflare),
        ("checking your browser", .cloudflare),
        ("attention required", .cloudflare),
        ("ray id", .cloudflare),
        ("g-recaptcha", .captcha),
        ("recaptcha", .captcha),
        ("hcaptcha", .captcha),
        ("cf-turnstile", .captcha),
        ("turnstile", .captcha),
        // 下面三条是**待匹配的页面正文**，不是界面文案：它们必须是站点真正
        // 写出来的那几个词，不能本地化，否则中文验证页会漏判（i18n-exempt）。
        ("请稍候", .generic),          // i18n-exempt
        ("正在验证", .generic),         // i18n-exempt
        ("需要验证", .generic),         // i18n-exempt
        ("verify you are human", .generic),
        ("enable javascript and cookies to continue", .generic),
    ]

    /// 判定一次响应是不是验证页。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 响应正文（只用来找标记，不做完整解析）。
    ///   - contentType: 响应类型；非 HTML 一律不判（图片、JSON 里出现这些词不算）。
    public static func detect(
        statusCode: Int,
        body: String?,
        contentType: String? = nil
    ) -> ChallengeHint? {
        guard challengeStatusCodes.contains(statusCode) else { return nil }
        if let contentType, !isHTML(contentType) { return nil }
        guard let body, !body.isEmpty else { return nil }

        let lowered = body.lowercased()
        for entry in markers where lowered.contains(entry.marker) {
            return ChallengeHint(kind: entry.kind, marker: entry.marker)
        }
        return nil
    }

    /// 从宿主侧的错误文案里嗅探。
    ///
    /// 脚本源的错误在传输过程中已经退化成一句文案（网络层的错误类型不会
    /// 原样穿过 JS 沙箱），所以只能从文案里找线索。判定刻意保守：
    /// 只认状态码与厂商名，不认「验证」这类泛词——文案里出现「验证」
    /// 更可能是「登录失效」而不是「人机校验」。
    public static func detect(inMessage message: String) -> ChallengeHint? {
        let lowered = message.lowercased()
        if lowered.contains("cloudflare") { return ChallengeHint(kind: .cloudflare, marker: "cloudflare") }
        if lowered.contains("captcha") { return ChallengeHint(kind: .captcha, marker: "captcha") }
        for code in challengeStatusCodes.sorted() {
            if lowered.contains("\(code)") {
                return ChallengeHint(kind: .generic, marker: "HTTP \(code)")
            }
        }
        return nil
    }

    /// 是否为 HTML 类型（缺省视为 HTML：很多服务器不带 `Content-Type`）。
    static func isHTML(_ contentType: String) -> Bool {
        let lowered = contentType.lowercased()
        if lowered.hasPrefix("text/html") { return true }
        if lowered.contains("html") { return true }
        if lowered.hasPrefix("text/") { return true }
        // 明确是别的类型就不判
        if lowered.contains("json") || lowered.contains("xml") || lowered.hasPrefix("image/") {
            return false
        }
        return true
    }
}
