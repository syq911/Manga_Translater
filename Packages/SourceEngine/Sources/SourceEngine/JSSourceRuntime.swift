//
//  JSSourceRuntime.swift
//  SourceEngine
//
//  源脚本的 JavaScriptCore 执行沙箱（`SourceRuntimeExecuting` 的 M2 实现）。
//
//  隔离与安全：
//  - **每个源一个 `JSVirtualMachine`**：不共享对象图与 GC，一个源无法影响另一个源；
//  - 全局只注入受控桥接（`net` / `cookies` / `prefs` / `log`），
//    没有文件系统、没有钥匙串、没有 URLSession 直接访问；
//  - 脚本装载前仍过一次静态校验（与安装时同一套规则），作为二次防线；
//  - 网络请求一律经 `SourceTransporting`，自动带该源 Cookie 并遵守节流。
//
//  桥接设计：Swift 与 JS 之间**只传字符串**。
//  对象在 JS 侧用一个很薄的包装层拼装（见 `bootstrapScript`），
//  这样 Swift 侧不必做复杂的 JSValue ↔ Swift 类型映射，出错面小得多。
//
//  线程模型：本类型是 `actor`，所有 `JSContext`/`JSValue` 访问都在 actor 隔离内
//  串行发生。JS 求值本身可能阻塞（脚本里的死循环无法被 JSC 中断），
//  因此调用层加了超时竞速：超时后**调用方立即返回**，不再等待 JS。
//
//  依赖：AppCore（模型）、ComicNet（HTTP/Cookie，经 SourceTransporting）。
//

import Foundation
import JavaScriptCore
import AppCore
import ComicNet

// MARK: - 源偏好设置

/// 源自定义设置的存储抽象（`prefs` 桥接的落点）。
public protocol SourcePreferencesStoring: Sendable {
    func value(forKey key: String) -> String?
    func setValue(_ value: String?, forKey key: String)
}

/// 基于 `UserDefaults` 的实现（键带 `source.<id>.` 前缀，源之间互不可见）。
public final class UserDefaultsSourcePreferences: SourcePreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: key)
    }

    public func setValue(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// 内存实现（测试与预览）。
public final class InMemorySourcePreferences: SourcePreferencesStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setValue(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}

// MARK: - Promise 结算

/// 承载 JS Promise 的 resolve/reject（跨并发边界传递，故标注 unchecked）。
final class JSPromiseSettlement: @unchecked Sendable {
    let resolve: JSValue?
    let reject: JSValue?

    init(resolve: JSValue?, reject: JSValue?) {
        self.resolve = resolve
        self.reject = reject
    }
}

// MARK: - 运行时

public actor JSSourceRuntime: SourceRuntimeExecuting {

    private let configuration: SourceRuntimeConfiguration
    private let transport: SourceTransporting
    private let preferences: SourcePreferencesStoring
    private let logSink: @Sendable (String, String) -> Void

    private var virtualMachine: JSVirtualMachine?
    private var context: JSContext?
    private var currentMeta: SourceScriptMeta?
    /// 桥接期间的错误（JS 侧拿到的 reject 文案）。
    private var lastException: String?

    public init(
        configuration: SourceRuntimeConfiguration = SourceRuntimeConfiguration(),
        transport: SourceTransporting,
        preferences: SourcePreferencesStoring = InMemorySourcePreferences(),
        logSink: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.preferences = preferences
        self.logSink = logSink
    }

    // MARK: 装载

    public func load(script: String, meta: SourceScriptMeta) async throws {
        teardown()

        // 二次防线：与安装时同一套规则（体积、禁用 API、元信息完整性）
        let validated: SourceScriptMeta
        do {
            validated = try SourceScriptValidator.validate(script)
        } catch {
            throw SourceRunnerError.scriptRejected(
                (error as? SourceScriptValidationError)?.message ?? error.localizedDescription
            )
        }
        guard validated.id == meta.id else {
            throw SourceRunnerError.scriptRejected(
                "脚本声明的来源 id（\(validated.id.rawValue)）与预期不符（\(meta.id.rawValue)）"
            )
        }

        let missing = SourceAPIContract.missingMethods(in: script)
        guard missing.isEmpty else {
            throw SourceRunnerError.incompleteContract(missing: missing.map(\.rawValue))
        }

        let machine = JSVirtualMachine()
        guard let ctx = JSContext(virtualMachine: machine) else {
            throw SourceRunnerError.executionFailed("无法创建 JavaScript 虚拟机")
        }

        ctx.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "未知 JavaScript 异常"
            // 异常处理器是同步回调，写共享状态需要回到 actor
            Task { await self?.recordException(text) }
        }

        self.virtualMachine = machine
        self.context = ctx
        self.currentMeta = meta
        self.lastException = nil

        installBridge(context: ctx, meta: meta)

        if let bootstrap = ctx.evaluateScript(Self.bootstrapScript), bootstrap.isUndefined {
            throw SourceRunnerError.executionFailed("桥接初始化失败：\(ctx.exception?.toString() ?? "未知错误")")
        }

        // 顶层求值：脚本此时只应做声明，不应真正发请求
        ctx.evaluateScript(script)
        if let exception = ctx.exception {
            let text = exception.toString() ?? "未知错误"
            teardown()
            throw SourceRunnerError.scriptRejected("脚本执行出错：\(text)")
        }
    }

    private func recordException(_ text: String) {
        lastException = text
    }

    // MARK: 调用

    public func call(_ method: SourceAPIMethod, arguments: [String]) async throws -> String {
        guard context != nil, currentMeta != nil else {
            throw SourceRunnerError.notInstalled(method.rawValue)
        }
        // 参数必须是合法 JSON（源契约里参数一律以 JSON 传递）
        for argument in arguments {
            guard let data = argument.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw SourceRunnerError.invalidResponse("参数不是合法 JSON：\(argument.prefix(60))")
            }
        }

        let argsJSON = Self.jsonArrayLiteral(arguments)
        let timeout = configuration.callTimeoutSeconds

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [self] in
                try await performCall(method, argsJSON: argsJSON)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                throw SourceRunnerError.executionTimeout(seconds: timeout)
            }
            guard let first = try await group.next() else {
                throw SourceRunnerError.executionFailed("调用未产出结果")
            }
            group.cancelAll()
            return first
        }
    }

    private func performCall(_ method: SourceAPIMethod, argsJSON: String) async throws -> String {
        guard let context else { throw SourceRunnerError.notInstalled(method.rawValue) }
        lastException = nil

        let body = """
        const __args = JSON.parse(__argsJSON);
        if (typeof \(method.rawValue) !== 'function') {
            throw new Error('源未实现方法：\(method.rawValue)');
        }
        const __value = await \(method.rawValue)(...__args);
        return JSON.stringify(__value === undefined ? null : __value);
        """

        do {
            let value = try await context.callAsyncJavaScript(
                body,
                arguments: ["__argsJSON": argsJSON],
                in: nil,
                contentWorld: .page
            )
            if let text = value.toString(), text != "undefined" {
                if let failure = lastException {
                    lastException = nil
                    throw SourceRunnerError.executionFailed(failure)
                }
                return text
            }
            throw SourceRunnerError.invalidResponse("源返回了空结果")
        } catch let error as SourceRunnerError {
            throw error
        } catch {
            throw SourceRunnerError.executionFailed(error.localizedDescription)
        }
    }

    public func teardown() {
        context = nil
        virtualMachine = nil
        currentMeta = nil
        lastException = nil
    }

    // MARK: 桥接注入

    private func installBridge(context: JSContext, meta: SourceScriptMeta) {
        let bridge = JSValue(newObjectIn: context)
        let sourceID = meta.id
        let rateLimit = meta.rateLimitMilliseconds

        // net.fetch(url, optionsJSON) → Promise<结果 JSON>
        let netFetch: @convention(block) (String, String) -> JSValue = { [weak self] url, optionsJSON in
            var settlement: JSPromiseSettlement?
            guard let promise = JSValue(newPromiseIn: context, fromExecutor: { resolve, reject in
                settlement = JSPromiseSettlement(resolve: resolve, reject: reject)
            }) else {
                return JSValue(undefinedIn: context)
            }
            guard let settlement else { return promise }
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.performBridgeFetch(
                    url: url,
                    optionsJSON: optionsJSON,
                    sourceID: sourceID,
                    rateLimitMilliseconds: rateLimit
                )
                await self.settle(settlement, with: outcome)
            }
            return promise
        }
        bridge?.setObject(netFetch as Any, forKeyedSubscript: "netFetch" as NSString)

        // 日志（只记级别与短消息，不落内容）
        let logInfo: @convention(block) (String) -> Void = { [weak self] message in
            Task { await self?.writeLog(level: "info", message: message, sourceID: sourceID) }
        }
        bridge?.setObject(logInfo as Any, forKeyedSubscript: "logInfo" as NSString)

        let cookiesGet: @convention(block) (String) -> String = { [weak self] url in
            // 读 Cookie 是同步的（CookieJar 内部加锁），但为保持单一入口仍走 actor；
            // 这里用一个短超时同步等待，避免在 JS 线程上无限阻塞。
            let semaphore = DispatchSemaphore(value: 0)
            let box = StringBox()
            Task { [weak self] in
                let value = await self?.bridgeCookieJSON(url: url, sourceID: sourceID) ?? "{}"
                box.value = value
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            return box.value ?? "{}"
        }
        bridge?.setObject(cookiesGet as Any, forKeyedSubscript: "cookiesGet" as NSString)

        let cookiesSet: @convention(block) (String, String) -> Void = { [weak self] url, json in
            Task { await self?.bridgeStoreCookies(url: url, json: json, sourceID: sourceID) }
        }
        bridge?.setObject(cookiesSet as Any, forKeyedSubscript: "cookiesSet" as NSString)

        // 读类桥接是**同步** API（脚本里写 `prefs.get(...)` 比 await 自然）。
        // 由于取值需要回到 actor，这里用短超时同步等待：actor 在
        // `await callAsyncJavaScript` 期间是空闲的，因此常规路径不会阻塞；
        // 极端情况（脚本在顶层同步调用）会等满超时并返回默认值，不会死锁。
        let prefsGet: @convention(block) (String) -> JSValue = { [weak self] key in
            guard let self else { return JSValue(nullIn: context) }
            let semaphore = DispatchSemaphore(value: 0)
            let box = StringBox()
            Task {
                box.value = await self.preferenceValue(key: key, sourceID: sourceID)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            guard let value = box.value else { return JSValue(nullIn: context) }
            return JSValue(object: value, in: context)
        }
        bridge?.setObject(prefsGet as Any, forKeyedSubscript: "prefsGet" as NSString)

        let prefsSet: @convention(block) (String, String) -> Void = { [weak self] key, value in
            Task { await self?.setPreferenceValue(value, key: key, sourceID: sourceID) }
        }
        bridge?.setObject(prefsSet as Any, forKeyedSubscript: "prefsSet" as NSString)

        context.setObject(bridge, forKeyedSubscript: "__bridge" as NSString)
    }

    /// 友好的 JS 侧 API（薄包装，全部逻辑在 Swift）。
    static let bootstrapScript = """
    (function () {
        const bridge = globalThis.__bridge;

        globalThis.net = {
            fetch: async function (url, options) {
                const raw = await bridge.netFetch(String(url), JSON.stringify(options || {}));
                const parsed = JSON.parse(raw);
                if (parsed.error) {
                    throw new Error(parsed.error);
                }
                return {
                    status: parsed.status,
                    ok: parsed.status >= 200 && parsed.status < 300,
                    headers: parsed.headers || {},
                    body: parsed.body,
                    text: parsed.body
                };
            }
        };

        globalThis.cookies = {
            getAll: function (url) { return JSON.parse(bridge.cookiesGet(String(url))); },
            get: function (url, name) {
                const all = JSON.parse(bridge.cookiesGet(String(url)));
                return (name === undefined || name === null) ? all : all[String(name)];
            },
            set: function (url, values) {
                bridge.cookiesSet(String(url), JSON.stringify(values || {}));
            }
        };

        globalThis.prefs = {
            get: function (key, fallback) {
                const value = bridge.prefsGet(String(key));
                return (value === null || value === undefined) ? fallback : value;
            },
            set: function (key, value) { bridge.prefsSet(String(key), String(value)); }
        };

        globalThis.log = {
            info: function (message) { bridge.logInfo(String(message)); },
            warn: function (message) { bridge.logInfo('WARN ' + String(message)); },
            error: function (message) { bridge.logInfo('ERROR ' + String(message)); }
        };
    })();
    """

    // MARK: 桥接实现（actor 隔离）

    private func performBridgeFetch(
        url: String,
        optionsJSON: String,
        sourceID: SourceID,
        rateLimitMilliseconds: Int
    ) async -> Result<SourceHTTPResult, Error> {
        do {
            let request = try Self.decodeRequest(url: url, optionsJSON: optionsJSON)
            let result = try await transport.send(
                request,
                sourceID: sourceID,
                rateLimitMilliseconds: rateLimitMilliseconds
            )
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func settle(_ settlement: JSPromiseSettlement, with outcome: Result<SourceHTTPResult, Error>) {
        guard let context else { return }
        switch outcome {
        case let .success(result):
            settlement.resolve?.call(withArguments: [
                Self.encodeResponse(result)
            ])
        case let .failure(error):
            let message = (error as? SourceTransportError)?.message
                ?? (error as? NetworkError)?.errorDescription
                ?? error.localizedDescription
            guard let object = JSValue(newObjectIn: context) else {
                settlement.reject?.call(withArguments: [message])
                return
            }
            object.setObject(message, forKeyedSubscript: "error" as NSString)
            settlement.resolve?.call(withArguments: [object.toString() ?? "{}"])
        }
    }

    private func writeLog(level: String, message: String, sourceID: SourceID) {
        // 只保留短消息，避免脚本把整页内容写进日志
        let trimmed = message.count > 200 ? String(message.prefix(200)) + "…" : message
        logSink(level, "[\(sourceID.rawValue)] \(trimmed)")
    }

    private func bridgeCookieJSON(url: String, sourceID: SourceID) async -> String {
        let items = await transport.cookies(for: url, sourceID: sourceID)
        var dict: [String: String] = [:]
        for item in items { dict[item.name] = item.value }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func bridgeStoreCookies(url: String, json: String, sourceID: SourceID) async {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any] else { return }
        var cookies: [String: String] = [:]
        for (key, value) in dict {
            cookies[key] = String(describing: value)
        }
        await transport.storeCookies(cookies, for: url, sourceID: sourceID)
    }

    private func preferenceValue(key: String, sourceID: SourceID) async -> String? {
        preferences.value(forKey: Self.preferenceKey(sourceID: sourceID, key: key))
    }

    private func setPreferenceValue(_ value: String, key: String, sourceID: SourceID) {
        preferences.setValue(value, forKey: Self.preferenceKey(sourceID: sourceID, key: key))
    }

    static func preferenceKey(sourceID: SourceID, key: String) -> String {
        "source.\(sourceID.rawValue).pref.\(key)"
    }

    // MARK: 纯函数

    /// 把 `net.fetch` 的 `url` + JSON options 解码为请求。
    static func decodeRequest(url: String, optionsJSON: String) throws -> SourceHTTPRequest {
        var method = "GET"
        var headers: [String: String] = [:]
        var body: String?
        var contentType: String?

        if let data = optionsJSON.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data),
           let object = raw as? [String: Any] {
            if let value = object["method"] as? String, !value.isEmpty {
                method = value.uppercased()
            }
            if let value = object["headers"] as? [String: Any] {
                for (key, headerValue) in value {
                    headers[key] = String(describing: headerValue)
                }
            }
            if let value = object["body"] as? String {
                body = value
            } else if let value = object["body"], !(value is NSNull) {
                // 允许提交对象：按表单编码
                if let dict = value as? [String: Any] {
                    body = dict
                        .map { "\($0.key)=\(String(describing: $0.value))" }
                        .sorted()
                        .joined(separator: "&")
                }
            }
            if let value = object["contentType"] as? String {
                contentType = value
            }
        }
        return SourceHTTPRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            contentType: contentType
        )
    }

    /// 把响应编码为 JS 侧便于 JSON.parse 的字符串。
    static func encodeResponse(_ result: SourceHTTPResult) -> String {
        let payload: [String: Any] = [
            "status": result.status,
            "headers": result.headers,
            "body": result.body,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"status\":\(result.status),\"headers\":{},\"body\":\"\"}"
        }
        return text
    }

    /// 把 JSON 字符串数组拼成 JS 数组字面量，作为 `JSON.parse` 的输入。
    static func jsonArrayLiteral(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

/// 极简线程安全字符串槽（用于在同步 block 里取异步结果）。
final class StringBox: @unchecked Sendable {
    private var storage: String?
    private let lock = NSLock()

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
