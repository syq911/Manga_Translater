//
//  SecureValueStore.swift
//  MangaTranslater
//
//  敏感值存储：Keychain 优先，失败回退本机存储。
//
//  存两类东西：翻译的自备 API Key、云服务账号的登录令牌。
//
//  为什么要有回退：侧载 / ad-hoc 签名下 Keychain 可能因缺少 entitlement 而写入失败。
//  「功能因为存不了密钥而整个不可用」比「密钥存在稍微弱一点的地方」糟糕得多，
//  因此 Keychain 写失败时回退到 UserDefaults，并在诊断日志里留痕，
//  让用户在排查时能看到「当前用的是回退存储」。
//
//  写入策略：**先写 Keychain；成功则清掉回退值**，避免出现「Keychain 里是新值、
//  回退里是旧值」这种读一次一个样的状态（读取以 Keychain 优先）。
//

import Foundation
import Security
import AppCore

enum SecureValueStore {

    /// 本 App 在 Keychain 里的服务名。
    ///
    /// 与 Bundle ID 对齐：Bundle ID 定死不改（《开发手册》2.3），
    /// 因此服务名也跟着稳定，免得升级后读不到旧令牌而要用户重新登录。
    private static let service = "com.mangatranslater.ios"

    /// 集中登记用到的键，避免各处拼字符串拼出错别字（读不到时会静默变成「未配置」）。
    enum Key {
        /// 自备翻译服务（OpenAI 兼容）的 API Key。
        static let translationAPIKey = "translation_api_key"
        /// 云服务的登录会话（令牌 + 到期时刻 + 账号快照的 JSON）。
        static let cloudSession = "cloud_session"
    }

    /// 当前是否在用回退存储（诊断面板展示用）。
    private(set) static var isUsingFallback = false

    // MARK: 读写

    static func string(forKey key: String) -> String? {
        if let value = keychainGet(key) { return value }
        return UserDefaults.standard.string(forKey: fallbackKey(key))
    }

    static func set(_ value: String, forKey key: String) {
        if value.isEmpty {
            remove(key)
            return
        }
        if keychainSet(value, key: key) {
            isUsingFallback = false
            UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        } else {
            isUsingFallback = true
            diag("安全存储: Keychain 写入失败，回退本机存储（key=\(key)）")
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    static func remove(_ key: String) {
        _ = keychainDelete(key)
        UserDefaults.standard.removeObject(forKey: fallbackKey(key))
    }

    // MARK: 内部

    private static func fallbackKey(_ key: String) -> String {
        "secure_fallback_\(key)"
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func keychainSet(_ value: String, key: String) -> Bool {
        var query = baseQuery(key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainGet(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func keychainDelete(_ key: String) -> Bool {
        SecItemDelete(baseQuery(key) as CFDictionary) == errSecSuccess
    }
}
