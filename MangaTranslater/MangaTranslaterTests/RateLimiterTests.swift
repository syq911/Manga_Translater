//
//  RateLimiterTests.swift
//  MangaTranslaterTests
//
//  覆盖请求节流：零间隔、间隔强制、注入时钟、取消传播、并发串行、参数边界。
//

import Testing
import Foundation
import ComicNet

@Suite("请求节流器")
struct RateLimiterTests {

    /// 可推进的假时钟 + 记录休眠请求。
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)
        private var sleeps: [TimeInterval] = []

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        var recordedSleeps: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return sleeps
        }

        func advance(_ interval: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(interval)
            lock.unlock()
        }

        /// 休眠实现：记录请求并推进假时钟。
        func sleep(_ interval: TimeInterval) async throws {
            lock.lock()
            sleeps.append(interval)
            lock.unlock()
            advance(interval)
        }
    }

    @Test("零间隔不产生等待")
    func zeroIntervalDoesNotSleep() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 0, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        try await limiter.acquire()
        try await limiter.acquire()

        #expect(clock.recordedSleeps.isEmpty)
        #expect(await limiter.currentMinInterval == 0)
    }

    @Test("首次请求不等待，第二次按间隔等待")
    func enforcesIntervalBetweenCalls() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 2, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        try await limiter.acquire()
        #expect(clock.recordedSleeps.isEmpty)

        try await limiter.acquire()
        #expect(clock.recordedSleeps.count == 1)
        #expect(abs(clock.recordedSleeps[0] - 2) < 0.001)
    }

    @Test("间隔内已过去的时间被扣除")
    func subtractsElapsedTime() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 5, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        try await limiter.acquire()
        clock.advance(4)
        try await limiter.acquire()

        #expect(clock.recordedSleeps.count == 1)
        #expect(abs(clock.recordedSleeps[0] - 1) < 0.001)
    }

    @Test("超过间隔后不再等待")
    func noWaitWhenIntervalAlreadyElapsed() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 1, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        try await limiter.acquire()
        clock.advance(10)
        try await limiter.acquire()

        #expect(clock.recordedSleeps.isEmpty)
    }

    @Test("负间隔被规范为 0")
    func negativeIntervalClamped() async throws {
        let limiter = RateLimiter(minInterval: -5, clock: { Date() }, sleeper: { _ in })
        #expect(await limiter.currentMinInterval == 0)
        try await limiter.acquire()
    }

    @Test("更新间隔立即生效")
    func updateIntervalTakesEffect() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 0, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        await limiter.updateMinInterval(3)
        try await limiter.acquire()
        try await limiter.acquire()

        #expect(clock.recordedSleeps.count == 1)
    }

    @Test("reset 清除历史后不再等待")
    func resetClearsHistory() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 5, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        try await limiter.acquire()
        await limiter.reset()
        try await limiter.acquire()

        #expect(clock.recordedSleeps.isEmpty)
        #expect(await limiter.lastAcquisitionDate != nil)
    }

    @Test("休眠被取消时错误向上传播")
    func cancellationPropagates() async {
        struct Boom: Error, Equatable {}
        let limiter = RateLimiter(
            minInterval: 1,
            clock: { Date() },
            sleeper: { _ in throw Boom() }
        )

        await expectThrowsAsync(Boom()) {
            try await limiter.acquire()
            try await limiter.acquire()
        }
    }

    @Test("并发调用被串行化，等待次数不超过调用数")
    func concurrentAcquisitionsAreSerialized() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 1, clock: { clock.now }, sleeper: { try await clock.sleep($0) })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try? await limiter.acquire() }
            }
        }

        // 5 次调用最多产生 4 次等待（首次不等待）
        #expect(clock.recordedSleeps.count <= 4)
        #expect(clock.recordedSleeps.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test("休眠实现不抛错时 acquire 不抛错")
    func acquireSucceedsWithNoopSleeper() async throws {
        let limiter = RateLimiter(minInterval: 0.001, clock: { Date() }, sleeper: { _ in })
        try await limiter.acquire()
        try await limiter.acquire()
    }
}
