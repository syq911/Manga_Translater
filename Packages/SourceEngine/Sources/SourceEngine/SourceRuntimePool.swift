//
//  SourceRuntimePool.swift
//  SourceEngine
//
//  已安装源的**运行时池**：按 key 缓存 `SourceRunner`，负责载入、复用与回收。
//
//  为什么必须有这一层：
//  1. 每个源一个 `JSVirtualMachine`，重复创建既慢又费内存——用户在同一源里
//     翻页时要复用同一个沙箱（脚本里的模块级状态也因此得以保留）；
//  2. 沙箱是**有配额**的资源，不能无限增长：超过上限就淘汰最久未用的那个；
//  3. 淘汰不能踩到正在使用中的沙箱，因此引入「租约」计数：
//     有租约的源不会被淘汰（宁可临时超限，也不能把别人的调用打断）。
//
//  并发要点：同一 key 的并发载入必须**只载入一次**（single-flight），
//  否则两个调用会各自建一个沙箱、互相覆盖。
//

import Foundation
import AppCore

/// 源运行时池。
public actor SourceRuntimePool {

    /// 池配置。
    public struct Configuration: Sendable, Equatable {
        /// 最多同时驻留的源数量。
        public var maxLoadedSources: Int

        public init(maxLoadedSources: Int = 3) {
            self.maxLoadedSources = max(1, maxLoadedSources)
        }
    }

    /// 运行时工厂：由调用方决定怎么建（App 用 JavaScriptCore，测试用替身）。
    public typealias RuntimeFactory = @Sendable (SourceScriptMeta) -> SourceRuntimeExecuting

    /// 运行时日志落地口（默认丢弃）。
    public typealias LogSink = @Sendable (String, String) -> Void

    private struct Entry {
        let runner: SourceRunner
        let meta: SourceScriptMeta
        /// 正在使用该源的任务数；> 0 时不允许淘汰。
        var leases: Int
    }

    private let store: SourceStore
    private let configuration: Configuration
    private let logSink: LogSink
    private let makeRuntime: RuntimeFactory

    private var entries: [String: Entry] = [:]
    /// 最近使用顺序（末尾最新），用于淘汰。
    private var accessOrder: [String] = []
    /// 正在载入中的任务（single-flight）。
    private var pending: [String: Task<SourceRunner, Error>] = [:]

    public init(
        store: SourceStore,
        configuration: Configuration = Configuration(),
        logSink: @escaping LogSink = { _, _ in },
        makeRuntime: @escaping RuntimeFactory
    ) {
        self.store = store
        self.configuration = configuration
        self.logSink = logSink
        self.makeRuntime = makeRuntime
    }

    // MARK: 状态查询

    /// 当前驻留的源 key（按最近使用排序，末尾最新）。
    public var loadedKeys: [String] { accessOrder }

    /// 某个源的运行是否已驻留。
    public func isLoaded(_ key: String) -> Bool { entries[key] != nil }

    /// 某个源已驻留时的元信息（未驻留返回 nil）。
    public func loadedMeta(_ key: String) -> SourceScriptMeta? { entries[key]?.meta }

    // MARK: 获取

    /// 取（必要时载入）某个源的 runner。
    ///
    /// - Warning: 这种方式拿到的 runner **不受租约保护**，可能在下一次
    ///   `runner(for:)` 触发淘汰时被回收。要保证「拿到直到用完都在」，
    ///   请用 `withRunner(for:_:)`。
    public func runner(for key: String) async throws -> SourceRunner {
        try await acquire(key)
    }

    /// 租约式使用：整个闭包执行期间该源不会被淘汰。
    public func withRunner<T: Sendable>(
        for key: String,
        _ body: @Sendable (SourceRunner) async throws -> T
    ) async throws -> T {
        let runner = try await acquire(key)
        do {
            let result = try await body(runner)
            release(key)
            return result
        } catch {
            release(key)
            throw error
        }
    }

    /// 释放租约（与 `runner(for:)` 配对使用；`withRunner` 已自动配对）。
    ///
    /// 多释放一次是安全的（计数不会降到 0 以下）。
    public func release(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.leases = max(0, entry.leases - 1)
        entries[key] = entry
    }

    // MARK: 回收

    /// 某个源被安装 / 更新 / 卸载后调用：丢掉旧沙箱，下次取用时重新载入。
    public func invalidate(_ key: String) async {
        pending[key]?.cancel()
        pending[key] = nil
        guard let entry = entries.removeValue(forKey: key) else {
            accessOrder.removeAll { $0 == key }
            return
        }
        accessOrder.removeAll { $0 == key }
        await entry.runner.teardown()
        logSink("info", "[源 \(key)] 已回收运行时")
    }

    /// 回收全部运行时（App 进入后台、或用户在设置里「全部重载」）。
    public func invalidateAll() async {
        for key in accessOrder {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            await entry.runner.teardown()
        }
        for (_, task) in pending { task.cancel() }
        pending.removeAll()
        accessOrder.removeAll()
        logSink("info", "[源] 已回收全部运行时")
    }

    // MARK: 内部

    private func acquire(_ key: String) async throws -> SourceRunner {
        guard ModelValidation.isValidSourceID(key) else {
            throw SourceRunnerError.notInstalled(key)
        }

        // 已驻留：刷新最近使用顺序后直接返回
        if var entry = entries[key] {
            entry.leases += 1
            entries[key] = entry
            touch(key)
            return entry.runner
        }

        // 已有同一来源的载入在途 → 复用它（single-flight）
        let task: Task<SourceRunner, Error>
        if let existing = pending[key] {
            task = existing
        } else {
            await evictIfNeeded(reserving: key)
            task = makeLoadTask(key)
            pending[key] = task
        }

        do {
            let runner = try await task.value
            pending[key] = nil
            // 无论这次载入是我的还是复用了别人的结果，都要在这里登记 + 记一次租约，
            // 否则「跟随者」拿到的 runner 没有租约，可能在使用中被淘汰。
            if var entry = entries[key] {
                entry.leases += 1
                entries[key] = entry
            } else {
                let meta = await runner.sourceMeta
                entries[key] = Entry(runner: runner, meta: meta, leases: 1)
                logSink("info", "[源 \(key)] 运行时已载入")
            }
            touch(key)
            return runner
        } catch {
            pending[key] = nil
            throw Self.normalize(error, key: key)
        }
    }

    /// 建一个「读脚本 → 校验 → 建运行时 → 载入」的任务。
    ///
    /// 只捕获局部常量（而不是 `self`），避免任务与池互相持有。
    private func makeLoadTask(_ key: String) -> Task<SourceRunner, Error> {
        let store = self.store
        let logSink = self.logSink
        let makeRuntime = self.makeRuntime
        return Task<SourceRunner, Error> {
            let script = try store.script(for: key)
            let meta = try SourceScriptValidator.validate(script)
            // 契约预检放在**建运行时之前**：沙箱是昂贵资源，
            // 脚本连必需方法都不全时没必要先把虚拟机建出来再扔掉。
            // 顺带把错误类型说清楚（`incompleteContract` 而不是笼统的执行失败）。
            let missing = SourceAPIContract.missingMethods(in: script)
            guard missing.isEmpty else {
                throw SourceRunnerError.incompleteContract(missing: missing.map(\.rawValue))
            }
            let runner = SourceRunner(runtime: makeRuntime(meta), meta: meta, logSink: logSink)
            try await runner.load(script: script)
            return runner
        }
    }

    /// 把 key 移到「最近使用」队尾。
    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// 需要时淘汰最久未使用的空闲源。带租约的一律跳过；若全都在用，暂时超限。
    private func evictIfNeeded(reserving key: String) async {
        while entries.count >= configuration.maxLoadedSources {
            let candidate = accessOrder.first { candidate in
                candidate != key && (entries[candidate]?.leases ?? 0) == 0
            }
            guard let candidate else {
                logSink("warn", "[源] 运行时长驻数量已达上限，但都在使用中，暂不淘汰")
                return
            }
            guard let entry = entries.removeValue(forKey: candidate) else {
                accessOrder.removeAll { $0 == candidate }
                continue
            }
            accessOrder.removeAll { $0 == candidate }
            await entry.runner.teardown()
            logSink("info", "[源 \(candidate)] 长期未使用，已回收运行时")
        }
    }

    /// 把底层错误统一成 `SourceRunnerError`，保持调用方只处理一种错误类型。
    private static func normalize(_ error: Error, key: String) -> SourceRunnerError {
        if let runnerError = error as? SourceRunnerError { return runnerError }
        if let validationError = error as? SourceScriptValidationError {
            return .scriptRejected(validationError.message)
        }
        // 脚本文件不见了 = 这个源没装（卸载后就属于这种情况），
        // 不该报成「执行失败」——UI 的提示文案完全不同。
        if let appError = error as? AppError, case .notFound = appError {
            return .notInstalled(key)
        }
        return .executionFailed(error.localizedDescription)
    }
}
