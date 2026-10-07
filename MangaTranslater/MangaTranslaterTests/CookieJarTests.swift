//
//  CookieJarTests.swift
//  MangaTranslaterTests
//
//  覆盖 Cookie 存储：来源隔离、覆盖写入、域名 / 路径匹配、过期清理、
//  持久化往返、损坏文件恢复、非法输入、并发访问。
//

import Testing
import Foundation
import AppCore
import ComicNet

@Suite("Cookie 存储")
struct CookieJarTests {

    private let alpha = SourceID("alpha")
    private let beta = SourceID("beta")

    @Test("写入后可读回")
    func setAndGet() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "session", value: "abc"), for: alpha)

        let cookies = jar.cookies(for: alpha)
        #expect(cookies.count == 1)
        #expect(cookies.first?.value == "abc")
        #expect(jar.hasCookies(for: alpha))
    }

    @Test("同名同域同路径覆盖而非重复")
    func overwritesSameCookie() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "session", value: "old", domain: "x.test"), for: alpha)
        try jar.set(StoredCookie(name: "session", value: "new", domain: "x.test"), for: alpha)

        let cookies = jar.cookies(for: alpha)
        #expect(cookies.count == 1)
        #expect(cookies.first?.value == "new")
    }

    @Test("不同域名同名 Cookie 共存")
    func differentDomainsCoexist() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "session", value: "a", domain: "a.test"), for: alpha)
        try jar.set(StoredCookie(name: "session", value: "b", domain: "b.test"), for: alpha)
        #expect(jar.cookies(for: alpha).count == 2)
    }

    @Test("来源之间完全隔离")
    func isolatesBetweenSources() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "session", value: "alpha-value"), for: alpha)
        try jar.set(StoredCookie(name: "session", value: "beta-value"), for: beta)

        #expect(jar.cookies(for: alpha).first?.value == "alpha-value")
        #expect(jar.cookies(for: beta).first?.value == "beta-value")
        #expect(jar.cookies(for: SourceID("gamma")).isEmpty)
    }

    @Test("空名 / 含分隔符的名称被拒绝")
    func rejectsInvalidNames() {
        let jar = CookieJar()
        expectThrows(AppError.invalidInput(Copy.text("error.cookie.nameEmpty"))) {
            try jar.set(StoredCookie(name: "   ", value: "v"), for: alpha)
        }
        expectThrows(AppError.invalidInput(Copy.format("error.cookie.nameInvalid", "a=b"))) {
            try jar.set(StoredCookie(name: "a=b", value: "v"), for: alpha)
        }
        expectThrows(AppError.invalidInput(Copy.text("error.cookie.valueHasNewline"))) {
            try jar.set(StoredCookie(name: "ok", value: "x\ny"), for: alpha)
        }
    }

    @Test("批量写入跳过非法项并返回被拒绝数量")
    func batchSetSkipsInvalid() {
        let jar = CookieJar()
        let rejected = jar.set([
            StoredCookie(name: "a", value: "1"),
            StoredCookie(name: "", value: "2"),
            StoredCookie(name: "b", value: "3"),
        ], for: alpha)

        #expect(rejected == 1)
        #expect(jar.cookies(for: alpha).count == 2)
    }

    @Test("域名匹配支持子域，拒绝无关域")
    func domainMatching() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "k", value: "v", domain: "example.com"), for: alpha)

        #expect(jar.cookies(for: alpha, host: "example.com").count == 1)
        #expect(jar.cookies(for: alpha, host: "sub.example.com").count == 1)
        #expect(jar.cookies(for: alpha, host: "notexample.com").isEmpty)
        #expect(jar.cookies(for: alpha, host: "example.org").isEmpty)
    }

    @Test("路径匹配按前缀")
    func pathMatching() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "k", value: "v", path: "/api"), for: alpha)

        #expect(jar.cookies(for: alpha, path: "/api/v1").count == 1)
        #expect(jar.cookies(for: alpha, path: "/other").isEmpty)
        #expect(jar.cookies(for: alpha, path: "/").isEmpty)
    }

    @Test("Cookie 串按预期拼接")
    func buildsCookieHeader() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "a", value: "1", domain: "x.test"), for: alpha)
        try jar.set(StoredCookie(name: "b", value: "2", domain: "x.test"), for: alpha)

        let header = try #require(jar.cookieHeader(for: alpha, url: "https://x.test/page"))
        #expect(header.contains("a=1"))
        #expect(header.contains("b=2"))
        #expect(header.contains("; "))
    }

    @Test("非法 URL 不产生 Cookie 串")
    func invalidURLProducesNoHeader() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "a", value: "1"), for: alpha)
        #expect(jar.cookieHeader(for: alpha, url: "not-a-url") == nil)
    }

    @Test("过期 Cookie 默认不返回，includeExpired 可强制返回")
    func expiryFiltering() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let jar = CookieJar(clock: { now })
        try jar.set(StoredCookie(name: "old", value: "1", expiresAt: now.addingTimeInterval(-1)), for: alpha)
        try jar.set(StoredCookie(name: "new", value: "2", expiresAt: now.addingTimeInterval(60)), for: alpha)
        try jar.set(StoredCookie(name: "session", value: "3"), for: alpha)

        #expect(jar.cookies(for: alpha).count == 2)
        #expect(jar.cookies(for: alpha, includeExpired: true).count == 3)
    }

    @Test("pruneExpired 清理过期项并返回条数")
    func pruneExpired() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let jar = CookieJar(clock: { now })
        try jar.set(StoredCookie(name: "old1", value: "1", expiresAt: now.addingTimeInterval(-1)), for: alpha)
        try jar.set(StoredCookie(name: "old2", value: "2", expiresAt: now.addingTimeInterval(-1)), for: beta)
        try jar.set(StoredCookie(name: "keep", value: "3", expiresAt: now.addingTimeInterval(60)), for: alpha)

        #expect(jar.pruneExpired() == 2)
        #expect(jar.cookies(for: alpha, includeExpired: true).count == 1)
        #expect(jar.cookies(for: beta, includeExpired: true).isEmpty)
    }

    @Test("删除单条与清空来源")
    func removeAndClear() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "a", value: "1"), for: alpha)
        try jar.set(StoredCookie(name: "b", value: "2"), for: alpha)

        #expect(jar.remove(name: "a", for: alpha))
        #expect(!jar.remove(name: "missing", for: alpha))
        #expect(jar.cookies(for: alpha).count == 1)

        jar.clear(sourceID: alpha)
        #expect(jar.cookies(for: alpha).isEmpty)
    }

    @Test("clearAll 清空全部来源")
    func clearAll() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "a", value: "1"), for: alpha)
        try jar.set(StoredCookie(name: "b", value: "2"), for: beta)
        jar.clearAll()
        #expect(jar.totalCount == 0)
        #expect(jar.sourceCount == 0)
    }

    @Test("持久化往返")
    func persistAndReload() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }
        let fileURL = directory.appendingPathComponent("cookies.json")

        let jar = CookieJar(storageURL: fileURL)
        try jar.set(StoredCookie(name: "a", value: "1", domain: "x.test"), for: alpha)
        try jar.persist()

        let reloaded = CookieJar(storageURL: fileURL)
        #expect(reloaded.cookies(for: alpha).first?.value == "1")
        #expect(reloaded.cookies(for: alpha).first?.domain == "x.test")
    }

    @Test("损坏的存储文件被备份并重置，不抛错")
    func corruptStorageIsRecovered() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }
        let fileURL = directory.appendingPathComponent("cookies.json")

        try Data("这不是 JSON".utf8).write(to: fileURL)
        let jar = CookieJar(storageURL: fileURL)

        #expect(jar.totalCount == 0)
        #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))

        // 恢复后仍可正常使用
        try jar.set(StoredCookie(name: "fresh", value: "1"), for: alpha)
        #expect(jar.cookies(for: alpha).count == 1)
    }

    @Test("无存储路径时 persist 为无操作")
    func persistWithoutStorageIsNoop() throws {
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "a", value: "1"), for: alpha)
        try jar.persist()
        #expect(jar.totalCount == 1)
    }

    @Test("并发写入不丢失条目")
    func concurrentWritesAreSafe() async throws {
        let jar = CookieJar()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try? jar.set(StoredCookie(name: "k\(index)", value: "v\(index)"), for: self.alpha)
                }
            }
        }
        #expect(jar.cookies(for: alpha).count == 100)
    }
}
