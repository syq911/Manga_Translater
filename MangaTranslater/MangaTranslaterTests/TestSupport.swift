//
//  TestSupport.swift
//  MangaTranslaterTests
//
//  测试共享工具：临时目录、错误断言、可控的「假」实现。
//
//  约定：
//  - 每个用例自己创建并清理临时目录，用例之间不共享状态；
//  - 不使用真实网络、不写用户目录，保证可重复执行。
//

import Foundation
import Testing
import AppCore
import ComicNet
import SourceEngine
import ComicDownload

// MARK: - 临时目录

enum TestFileSystem {
    /// 创建用例专属临时目录。
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaTranslaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 递归删除（清理用；失败不抛错，避免掩盖真实断言）。
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 错误断言

/// 断言抛出指定错误（要求错误类型可比较）。
func expectThrows<E: Error & Equatable>(
    _ expected: E,
    _ comment: Comment? = nil,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record(comment ?? "期望抛出 \(expected)，但未抛错")
    } catch let error as E {
        #expect(error == expected, comment)
    } catch {
        Issue.record(comment ?? "期望抛出 \(expected)，实际抛出 \(error)")
    }
}

/// 断言抛出指定错误（异步版本）。
func expectThrowsAsync<E: Error & Equatable>(
    _ expected: E,
    _ comment: Comment? = nil,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record(comment ?? "期望抛出 \(expected)，但未抛错")
    } catch let error as E {
        #expect(error == expected, comment)
    } catch {
        Issue.record(comment ?? "期望抛出 \(expected)，实际抛出 \(error)")
    }
}

// MARK: - 假实现

/// 可脚本化的传输层：按调用顺序返回预设结果或抛错。
final class StubTransport: HTTPTransporting, @unchecked Sendable {

    enum Outcome {
        case success(data: Data, statusCode: Int, headers: [String: String])
        case failure(NetworkError)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var recorded: [URLRequest] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    convenience init(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
        self.init(outcomes: [.success(data: data, statusCode: statusCode, headers: headers)])
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var requestCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        let outcome: Outcome
        if outcomes.count > 1 {
            outcome = outcomes.removeFirst()
        } else {
            outcome = outcomes.first ?? .failure(.transport("stub 未配置"))
        }
        lock.unlock()

        switch outcome {
        case let .success(data, statusCode, headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers
                  ) else {
                throw NetworkError.transport("无法构造响应")
            }
            return (data, response)
        case let .failure(error):
            throw error
        }
    }
}

/// 可脚本化的取页实现。
final class StubPageFetcher: PageFetching, @unchecked Sendable {

    private let lock = NSLock()
    private var scriptedResults: [Result<Data, Error>]
    private var callCounts: [String: Int] = [:]
    private var inFlight = 0
    private var peakInFlight = 0

    init(scriptedResults: [Result<Data, Error>]) {
        self.scriptedResults = scriptedResults
    }

    convenience init(pageData: Data = Data(repeating: 0xAB, count: 64)) {
        self.init(scriptedResults: [.success(pageData)])
    }

    /// 观测到的最大并发抓取数（用于验证并发上限）。
    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakInFlight
    }

    var totalCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts.values.reduce(0, +)
    }

    func calls(for url: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[url] ?? 0
    }

    func fetchPage(url: String, headers: [String: String]) async throws -> Data {
        lock.lock()
        callCounts[url, default: 0] += 1
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        let result: Result<Data, Error>?
        if scriptedResults.count > 1 {
            result = scriptedResults.removeFirst()
        } else {
            result = scriptedResults.first
        }
        lock.unlock()

        defer {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }

        try? await Task.sleep(nanoseconds: 500_000)

        guard let result else {
            throw AppError.unknown("stub 未配置结果")
        }
        return try result.get()
    }
}

/// 会在指定次数后开始失败的文件系统实现（验证回滚路径）。
final class FailingFileSystem: SourceFileSystem, @unchecked Sendable {

    private let inner = DefaultSourceFileSystem()
    private let lock = NSLock()
    private var writeFailureAfter: Int?
    private var writeCount = 0
    private var moveFailureFrom: String?

    init(writeFailureAfter: Int? = nil, moveFailureFrom: String? = nil) {
        self.writeFailureAfter = writeFailureAfter
        self.moveFailureFrom = moveFailureFrom
    }

    func ensureDirectory(at url: URL) throws { try inner.ensureDirectory(at: url) }
    func exists(at url: URL) -> Bool { inner.exists(at: url) }
    func read(from url: URL) throws -> Data { try inner.read(from: url) }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        writeCount += 1
        let shouldFail = writeFailureAfter.map { writeCount > $0 } ?? false
        lock.unlock()
        if shouldFail {
            throw AppError.fileSystem("注入的写入失败")
        }
        try inner.write(data, to: url)
    }

    func move(from source: URL, to destination: URL) throws {
        lock.lock()
        let shouldFail = moveFailureFrom.map { source.lastPathComponent.contains($0) } ?? false
        lock.unlock()
        if shouldFail {
            throw AppError.fileSystem("注入的移动失败")
        }
        try inner.move(from: source, to: destination)
    }

    func remove(at url: URL) throws { try inner.remove(at: url) }
    func listFiles(in url: URL) throws -> [String] { try inner.listFiles(in: url) }
}
