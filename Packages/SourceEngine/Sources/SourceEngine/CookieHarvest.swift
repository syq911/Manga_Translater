//
//  CookieHarvest.swift
//  SourceEngine
//
//  内嵌网页登录之后的 Cookie 收割。
//
//  背景（契约 §8）：源自己不实现登录，用户在内嵌网页里登录，
//  宿主把 Cookie 收割到**该源独立的容器**，之后源脚本用 `net.*` 发请求时
//  宿主自动带上。
//
//  三个必须守住的点：
//  1. **按主机过滤**：登录过程中网页会访问 CDN、统计、第三方登录域。
//     把整站所有 Cookie 都倒进源容器，等于让「登录 acg 站」顺带把
//     「登录 Google」的凭据也交出去。只收与登录页同一主机（或其父域）的。
//  2. **过期不收**：过期 Cookie 塞进容器只会在下次请求时产生怪异行为。
//  3. **同名覆盖**：同一来源重复登录时，新值必须盖掉旧值（否则用户
//     「重新登录后仍然没权限」）。
//
//  这里的逻辑不依赖 WebKit：WebKit 的 `HTTPCookie` 只在适配器里出现，
//  核心规则可以纯函数单测（CI 里没有真实的网页可以登录）。
//

import Foundation
import AppCore
import ComicNet

/// 从网页里收割到的一枚 Cookie。
public struct HarvestedCookie: Equatable, Sendable {
    public let name: String
    public let value: String
    /// 归属域；空串表示「该来源下所有域名通用」。
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresAt: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    /// 从 `HTTPCookiePropertyKey` 字典构造（WebKit 的 `HTTPCookie` 是它的子类）。
    public init(properties: [HTTPCookiePropertyKey: Any]) {
        self.name = (properties[.name] as? String) ?? ""
        self.value = (properties[.value] as? String) ?? ""
        self.domain = (properties[.domain] as? String) ?? ""
        self.path = (properties[.path] as? String) ?? "/"
        self.expiresAt = properties[.expires] as? Date
        self.isSecure = Self.flag(properties[.secure])
        // `HttpOnly` 不是公开的标准键，WebKit 用的是这个字符串键；
        // 读不到就当 false（不影响功能，只是不标记为仅 HTTP）。
        self.isHTTPOnly = Self.flag(properties[HTTPCookiePropertyKey("HttpOnly")])
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let boolean as Bool: return boolean
        case let text as String: return text.uppercased() == "TRUE" || text == "1"
        default: return false
        }
    }

    /// 是否已过期。
    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// 宿主容器能否真的存下这条 Cookie。
    ///
    /// 规则与 `CookieJar.set` 一致（它是唯一的事实来源）：
    /// 名称非空、不含 `;` `=` 换行；值不含换行。
    /// **在过滤阶段就拒掉**，这样「收下的一定写得进去」，
    /// 于是清空旧凭据这件事不会白做。
    public var isStorable: Bool {
        guard !name.isEmpty else { return false }
        guard !name.contains(";"), !name.contains("="), !name.contains("\n") else { return false }
        guard !value.contains("\n") else { return false }
        return true
    }

    /// 转成宿主容器的存储形态。
    public var stored: StoredCookie {
        StoredCookie(
            name: name,
            value: value,
            domain: Self.normalizeDomain(domain),
            path: path,
            expiresAt: expiresAt,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly
        )
    }

    /// 去掉前导点并转小写：`".Example.com"` 与 `"example.com"` 是同一个域。
    ///
    /// 必须归一化：`StoredCookie.matches(host:)` 是按后缀比较的，
    /// 留着前导点会变成「永远匹配不上」，表现为「登录了但请求不带 Cookie」。
    public static func normalizeDomain(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }
}

/// 收割规则。
public enum CookieHarvest {

    /// 从登录页地址取主机名（小写、去端口）。
    public static func host(of urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty
        else { return nil }
        return host.lowercased()
    }

    /// 这枚 Cookie 是否属于该主机。
    ///
    /// - 空域（来源通用）→ 收；
    /// - 完全同域 → 收；
    /// - 本主机是 Cookie 域的**子域**（`img.example.com` 之于 `example.com`）→ 收；
    /// - 其余（第三方域）→ 丢。
    public static func belongs(domain rawDomain: String, to host: String) -> Bool {
        let domain = HarvestedCookie.normalizeDomain(rawDomain)
        guard !domain.isEmpty else { return true }
        let target = host.lowercased()
        if target == domain { return true }
        return target.hasSuffix("." + domain)
    }

    /// 过滤出该主机可收的 Cookie（并去掉过期与无名项）。
    public static func filter(
        _ cookies: [HarvestedCookie],
        forHost host: String?,
        at date: Date = Date()
    ) -> [HarvestedCookie] {
        cookies.filter { cookie in
            guard cookie.isStorable else { return false }
            guard !cookie.isExpired(at: date) else { return false }
            guard let host else { return true }
            return belongs(domain: cookie.domain, to: host)
        }
    }

    /// 过滤并写入某个来源的容器。
    ///
    /// - Returns: 真正写入的条数。
    ///
    /// 写入前会把该来源的旧 Cookie 清掉：用户「重新登录」的语义是用新身份
    /// 覆盖旧的，留着旧 session 会让请求带着两个同名 Cookie，服务端行为不可预测。
    @discardableResult
    public static func merge(
        _ cookies: [HarvestedCookie],
        into jar: CookieJar,
        sourceID: SourceID,
        forHost host: String?,
        at date: Date = Date()
    ) -> Int {
        let accepted = filter(cookies, forHost: host, at: date)
        guard !accepted.isEmpty else { return 0 }
        jar.clear(sourceID: sourceID)
        // 同名同域同路径的以最后一次为准：`set` 内部是按（name, domain, path）替换的，
        // 这里先去重以让计数准确。
        var unique: [String: HarvestedCookie] = [:]
        for cookie in accepted {
            let key = "\(cookie.name.lowercased())|\(HarvestedCookie.normalizeDomain(cookie.domain))|\(cookie.path)"
            unique[key] = cookie
        }
        // 注意 `CookieJar.set(_:for:)` 返回的是**被拒绝的条数**（不是写入条数）——
        // 直接把它当「写了几条」会让界面显示「已保存 0 条凭据」，用户以为登录没生效。
        let stored = unique.values.map(\.stored)
        let rejected = jar.set(stored, for: sourceID)
        return max(0, stored.count - rejected)
    }
}
