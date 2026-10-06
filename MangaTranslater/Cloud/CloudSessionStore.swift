//
//  CloudSessionStore.swift
//  MangaTranslater
//
//  云服务登录会话的持久化。
//
//  会话整体（令牌 + 到期时刻 + 账号快照）序列化成一段 JSON 存起来。
//
//  为什么整体存而不是拆成「令牌放钥匙串、账号放 UserDefaults」：
//  令牌与它对应的账号信息是**一起**才有意义的。拆开存就会出现
//  「令牌换了、账号快照还是上一个的」这种状态，而它表现出来只是界面上
//  名字或额度不对——很难联想到存储层。
//
//  为什么要有协议：账号模型的边界条件（令牌过期、验证码错、额度耗尽）
//  必须在**不碰真实钥匙串**的前提下可测。测试注入内存实现即可。
//

import Foundation
import AppCore

/// 会话存储。
protocol CloudSessionStoring: Sendable {
    func load() -> CloudSession?
    func save(_ session: CloudSession)
    func clear()
}

// MARK: - 生产实现

/// 落在 `SecureValueStore`（Keychain 优先，失败回退本机存储）。
struct CloudSessionStore: CloudSessionStoring {

    private var key: String { SecureValueStore.Key.cloudSession }

    /// 生产环境的实例。
    static func live() -> CloudSessionStoring { CloudSessionStore() }

    /// 读取已保存的会话。损坏或不存在返回 nil（并清掉脏数据，避免每次启动都解析失败）。
    func load() -> CloudSession? {
        guard let raw = SecureValueStore.string(forKey: key), !raw.isEmpty else { return nil }
        guard let data = raw.data(using: .utf8) else {
            clear()
            return nil
        }
        do {
            return try JSONDecoder().decode(CloudSession.self, from: data)
        } catch {
            diag("云会话: 本地会话无法解析，已清除 —— \(error.localizedDescription)")
            clear()
            return nil
        }
    }

    func save(_ session: CloudSession) {
        do {
            let data = try JSONEncoder().encode(session)
            guard let text = String(data: data, encoding: .utf8) else {
                diag("云会话: 序列化结果不是合法 UTF-8，已放弃保存")
                return
            }
            SecureValueStore.set(text, forKey: key)
        } catch {
            diag("云会话: 序列化失败 —— \(error.localizedDescription)")
        }
    }

    func clear() {
        SecureValueStore.remove(key)
    }
}

// MARK: - 测试 / 预览用

/// 内存会话存储。
final class InMemoryCloudSessionStore: CloudSessionStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: CloudSession?
    /// 记录调用次数，便于断言「401 之后确实清了会话」。
    private(set) var clearCount = 0

    init(session: CloudSession? = nil) {
        self.stored = session
    }

    func load() -> CloudSession? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ session: CloudSession) {
        lock.lock()
        stored = session
        lock.unlock()
    }

    func clear() {
        lock.lock()
        stored = nil
        clearCount += 1
        lock.unlock()
    }
}
