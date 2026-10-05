//
//  DiagnosticsTests.swift
//  MangaTranslaterTests
//
//  覆盖诊断日志：写入 / 读取 / 轮转 / 清理 / 并发 / 异常输入。
//

import Testing
import Foundation
import AppCore

@Suite("诊断日志")
struct DiagnosticsTests {

    @Test("写入后可读回内容")
    func writeAndRead() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let log = DiagnosticsLog(directory: directory, fileName: "a.log")
        log.log("hello")
        log.log("world")

        let content = log.readAll()
        #expect(content.contains("hello"))
        #expect(content.contains("world"))
        #expect(log.byteCount > 0)
    }

    @Test("空消息与纯空白消息被忽略")
    func ignoresBlankMessages() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let log = DiagnosticsLog(directory: directory, fileName: "b.log")
        log.log("")
        log.log("   \n\t ")
        #expect(log.readAll().isEmpty)
        #expect(log.byteCount == 0)
    }

    @Test("目录不存在时自动创建")
    func createsMissingDirectory() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let nested = root.appendingPathComponent("deep/nested", isDirectory: true)
        let log = DiagnosticsLog(directory: nested, fileName: "c.log")
        log.log("auto-created")

        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(log.readAll().contains("auto-created"))
    }

    @Test("超过上限自动轮转并保留一份历史")
    func rotatesWhenExceedingLimit() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        // 上限压到最小（实现内下限 1024），写入多行触发轮转
        let log = DiagnosticsLog(directory: directory, fileName: "d.log", maxBytes: 1024)
        for index in 0..<80 {
            log.log("line-\(index)-" + String(repeating: "x", count: 40))
        }

        #expect(FileManager.default.fileExists(atPath: log.rotatedFileURL.path))
        #expect(log.byteCount <= 1024)
    }

    @Test("清空后内容为空且轮转文件被删除")
    func clearRemovesEverything() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let log = DiagnosticsLog(directory: directory, fileName: "e.log", maxBytes: 1024)
        for index in 0..<80 {
            log.log("line-\(index)-" + String(repeating: "y", count: 40))
        }
        log.clear()

        #expect(log.readAll().isEmpty)
        #expect(log.byteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: log.rotatedFileURL.path))
    }

    @Test("指定时间写入时按给定时间格式化")
    func writesProvidedTimestamp() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let log = DiagnosticsLog(directory: directory, fileName: "f.log")
        let date = Date(timeIntervalSince1970: 0)
        log.log("epoch", at: date)

        #expect(log.readAll().contains("1970-01-01T00:00:00.000Z"))
    }

    @Test("多行消息完整保留")
    func preservesMultiline() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let log = DiagnosticsLog(directory: directory, fileName: "g.log")
        log.log("first\nsecond")
        let content = log.readAll()
        #expect(content.contains("first"))
        #expect(content.contains("second"))
    }

    @Test("并发写入不丢行且行数正确")
    func concurrentWritesAreSafe() async throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let log = DiagnosticsLog(directory: directory, fileName: "h.log", maxBytes: 10 * 1024 * 1024)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { log.log("concurrent-\(index)") }
            }
        }

        let content = log.readAll()
        for index in 0..<100 {
            #expect(content.contains("concurrent-\(index)"))
        }
    }

    @Test("全局 diag 函数可用")
    func globalDiagWorks() {
        let before = DiagnosticsLog.shared.byteCount
        diag("全局打点测试")
        #expect(DiagnosticsLog.shared.byteCount > before)
    }
}
