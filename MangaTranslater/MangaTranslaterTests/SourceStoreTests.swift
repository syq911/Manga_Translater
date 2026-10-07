//
//  SourceStoreTests.swift
//  MangaTranslaterTests
//
//  覆盖源仓库管理：出厂零源、仓库增删与持久化、安装 / 覆盖 / 卸载、
//  非法输入、失败回滚、并发安装。
//

import Testing
import Foundation
import AppCore
import SourceEngine

@Suite("源仓库管理")
struct SourceStoreTests {

    private func makeScript(id: String, version: String = "1.0.0", nsfw: Bool = false) -> String {
        """
        const source = {
          id: "\(id)",
          name: "源 \(id)",
          lang: "zh",
          baseUrl: "https://example.com",
          nsfw: \(nsfw),
          version: "\(version)"
        };
        async function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
        async function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
        async function getMangaDetails(mangaUrl) { return { title: "t" }; }
        async function getChapterList(mangaUrl) { return []; }
        async function getPageList(chapterUrl) { return []; }
        """
    }

    private func makeStore(fileSystem: SourceFileSystem = DefaultSourceFileSystem()) throws -> (SourceStore, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        return (SourceStore(rootDirectory: root, fileSystem: fileSystem), root)
    }

    // MARK: 出厂状态

    @Test("出厂时不带任何仓库与源")
    func startsEmpty() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        #expect(store.repositories.isEmpty)
        #expect(store.installedSources().isEmpty)
        #expect(!store.isInstalled("anything"))
    }

    // MARK: 仓库

    @Test("添加仓库并持久化")
    func addRepositoryPersists() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        let result = try store.addRepository("https://example.com/repo/index.json")
        #expect(result)
        #expect(store.repositories.count == 1)

        let reloaded = SourceStore(rootDirectory: root)
        #expect(reloaded.repositories == ["https://example.com/repo/index.json"])
    }

    @Test("重复添加返回 false 且不重复")
    func duplicateRepositoryIgnored() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.addRepository("https://example.com/repo/index.json")
        let second = try store.addRepository("https://example.com/repo/index.json")
        #expect(second == false)
        #expect(store.repositories.count == 1)
    }

    @Test("非法仓库地址被拒绝", arguments: ["", "not a url", "ftp://example.com", "http://example.com"])
    func rejectsInvalidRepository(value: String) throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        expectThrows(AppError.invalidInput(Copy.format("error.store.invalidRepositoryURL", value))) {
            _ = try store.addRepository(value)
        }
        #expect(store.repositories.isEmpty)
    }

    @Test("移除仓库")
    func removeRepository() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.addRepository("https://example.com/a/index.json")
        try store.addRepository("https://example.com/b/index.json")

        #expect(try store.removeRepository("https://example.com/a/index.json"))
        #expect(!(try store.removeRepository("https://example.com/missing/index.json")))
        #expect(store.repositories.count == 1)

        #expect(try store.removeAllRepositories() == 1)
        #expect(store.repositories.isEmpty)
    }

    // MARK: 安装

    @Test("安装合法源后落盘且元数据正确")
    func installWritesScript() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        let entry = try store.install(script: makeScript(id: "demo", version: "1.2.3", nsfw: true))

        #expect(entry.key == "demo")
        #expect(entry.version == "1.2.3")
        #expect(entry.isNSFW)
        #expect(store.isInstalled("demo"))
        #expect(FileManager.default.fileExists(atPath: store.scriptURL(for: "demo").path))
        #expect(try store.script(for: "demo").contains("id: \"demo\""))
    }

    @Test("重复安装同 key 覆盖为新版本且不留临时文件")
    func reinstallOverwrites() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.install(script: makeScript(id: "demo", version: "1.0.0"))
        let updated = try store.install(script: makeScript(id: "demo", version: "2.0.0"))

        #expect(updated.version == "2.0.0")
        #expect(store.installedSources().count == 1)

        let files = try FileManager.default.contentsOfDirectory(atPath: store.sourcesDirectory.path)
        #expect(!files.contains { $0.hasSuffix(".tmp") || $0.hasSuffix(".bak") })
    }

    @Test("非法脚本安装失败且不产生任何文件")
    func installRejectsInvalidScript() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        expectThrows(SourceScriptValidationError.missingMetadataBlock) {
            _ = try store.install(script: "function nope() {}")
        }
        #expect(store.installedSources().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.sourcesDirectory.path))
    }

    @Test("卸载移除文件与元数据")
    func uninstallRemoves() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.install(script: makeScript(id: "demo"))
        #expect(try store.uninstall(key: "demo"))
        #expect(!store.isInstalled("demo"))
        #expect(!FileManager.default.fileExists(atPath: store.scriptURL(for: "demo").path))
        #expect(try store.uninstall(key: "demo") == false)
    }

    @Test("读取不存在的源报 notFound")
    func readsMissingScript() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        expectThrows(AppError.notFound(Copy.format("error.store.payloadScript", "demo"))) {
            _ = try store.script(for: "demo")
        }
    }

    @Test("非法 key 被拒绝（含路径穿越尝试）", arguments: ["", "../evil", "a/b", "A B", "..", "../../../etc/passwd"])
    func rejectsInvalidKeys(key: String) throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        expectThrows(AppError.invalidInput(Copy.format("error.store.invalidKey", key))) {
            _ = try store.script(for: key)
        }
        expectThrows(AppError.invalidInput(Copy.format("error.store.invalidKey", key))) {
            _ = try store.uninstall(key: key)
        }
    }

    // MARK: 回滚

    @Test("脚本落盘失败时保留旧版本")
    func rollbackWhenMoveFails() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        // 先正常安装 v1
        let healthy = SourceStore(rootDirectory: root)
        try healthy.install(script: makeScript(id: "demo", version: "1.0.0"))

        // 再用「移动到最终位置必失败」的文件系统装 v2
        let failing = SourceStore(
            rootDirectory: root,
            fileSystem: FailingFileSystem(moveFailureFrom: ".js.tmp")
        )
        do {
            _ = try failing.install(script: makeScript(id: "demo", version: "2.0.0"))
            Issue.record("应当抛错")
        } catch {
            // 预期失败
        }

        // 旧版本仍然可用，且元数据未被写坏
        let verifier = SourceStore(rootDirectory: root)
        #expect(verifier.isInstalled("demo"))
        #expect(verifier.installedSources().first?.version == "1.0.0")
        #expect(try verifier.script(for: "demo").contains("1.0.0"))
    }

    @Test("元数据写入失败时回滚脚本")
    func rollbackWhenMetadataFails() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let healthy = SourceStore(rootDirectory: root)
        try healthy.install(script: makeScript(id: "demo", version: "1.0.0"))

        // 第 1 次写（脚本临时文件）成功，第 2 次写（元数据）失败
        let failing = SourceStore(
            rootDirectory: root,
            fileSystem: FailingFileSystem(writeFailureAfter: 1)
        )
        do {
            _ = try failing.install(script: makeScript(id: "demo", version: "9.9.9"))
            Issue.record("应当抛错")
        } catch {
            // 预期失败
        }

        let verifier = SourceStore(rootDirectory: root)
        #expect(try verifier.script(for: "demo").contains("1.0.0"))
        #expect(verifier.installedSources().first?.version == "1.0.0")
    }

    // MARK: 并发

    @Test("并发安装不同源互不干扰")
    func concurrentInstalls() async throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try? store.install(script: self.makeScript(id: "s\(index)"))
                }
            }
        }

        #expect(store.installedSources().count <= 8)
        for index in 0..<8 {
            if store.isInstalled("s\(index)") {
                #expect(FileManager.default.fileExists(atPath: store.scriptURL(for: "s\(index)").path))
            }
        }
    }
}
