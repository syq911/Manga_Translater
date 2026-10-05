//
//  RateLimiter.swift
//  ComicNet
//
//  按「来源」维度的请求节流器：保证同一来源两次请求之间至少间隔
//  `minInterval` 秒。用于遵守脆弱站点的访问频率要求，避免被封。
//
//  时间源与休眠实现均可注入，测试无需真实等待。
//

import Foundation

/// 请求节流器（actor：并发调用自动串行）。
public actor RateLimiter {

    private var minInterval: TimeInterval
    private var lastAcquisition: Date?
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - minInterval: 最小间隔（秒）。≤0 表示不节流。
    ///   - clock: 当前时间来源。
    ///   - sleeper: 休眠实现（可注入，便于测试）。
    public init(
        minInterval: TimeInterval = 0,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            guard interval > 0 else { return }
            let nanoseconds = UInt64((interval * 1_000_000_000).rounded())
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.minInterval = max(0, minInterval)
        self.clock = clock
        self.sleeper = sleeper
    }

    /// 取得一次「发送许可」。必要时等待到满足最小间隔。
    /// - Throws: 休眠被取消时抛出（通常是 `CancellationError`）。
    public func acquire() async throws {
        guard minInterval > 0 else {
            lastAcquisition = clock()
            return
        }

        if let last = lastAcquisition {
            let elapsed = clock().timeIntervalSince(last)
            let remaining = minInterval - elapsed
            if remaining > 0 {
                try await sleeper(remaining)
            }
        }
        lastAcquisition = clock()
    }

    /// 更新最小间隔（≤0 视为不节流）。
    public func updateMinInterval(_ value: TimeInterval) {
        minInterval = max(0, value)
    }

    /// 当前最小间隔。
    public var currentMinInterval: TimeInterval { minInterval }

    /// 上一次取得许可的时间（nil 表示尚未请求过）。
    public var lastAcquisitionDate: Date? { lastAcquisition }

    /// 清空节流状态（切换来源或用户手动重试时使用）。
    public func reset() {
        lastAcquisition = nil
    }
}
