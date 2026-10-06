//
//  HostedServerTests.swift
//  MangaTranslaterTests
//
//  自建服务器的配置模型与存储。
//
//  重点在两处容易出错的地方：
//  1. 由名字派生 `SourceID`：它的字符集限制很窄（小写字母数字与 `-`、`_`），
//     中文名、空格、大写都很常见，派生逻辑错一步就是「加不上服务器」；
//  2. 地址规范化：`https://a.com/komga/` 与 `https://a.com/komga` 必须等价，
//     而中间的斜杠是路径的一部分，不能一起删。
//

import Foundation
import Testing
import AppCore
import SourceEngine

@Suite("自建服务器配置")
struct HostedServerTests {

    // MARK: 地址

    @Test("地址规范化：只去尾部斜杠，不动中间的")
    func normalizesBaseURL() {
        #expect(HostedServer.normalizeBaseURL("https://a.com/komga/") == "https://a.com/komga")
        #expect(HostedServer.normalizeBaseURL("https://a.com/komga") == "https://a.com/komga")
        #expect(HostedServer.normalizeBaseURL("https://a.com/komga///") == "https://a.com/komga")
        #expect(HostedServer.normalizeBaseURL("  https://a.com/komga/  ") == "https://a.com/komga")
        #expect(HostedServer.normalizeBaseURL("https://a.com/a/b/") == "https://a.com/a/b")
    }

    @Test("地址合法性：必须 http(s) 且带主机名")
    func validatesBaseURL() {
        #expect(HostedServer.isValidBaseURL("https://nas.local:25600"))
        #expect(HostedServer.isValidBaseURL("http://192.168.1.10:8080/komga"))
        #expect(HostedServer.isValidBaseURL("nas.local") == false)
        #expect(HostedServer.isValidBaseURL("ftp://nas.local") == false)
        #expect(HostedServer.isValidBaseURL("https:///nohost") == false)
        #expect(HostedServer.isValidBaseURL("") == false)
    }

    // MARK: 标识派生

    @Test("标识由种类与名称派生：永远是小写字母数字或连字符")
    func derivesValidIdentifier() {
        let id = HostedServer.makeID(kind: .komga, name: "我的 NAS", existing: [])
        #expect(ModelValidation.isValidSourceID(id))
        #expect(id.hasPrefix("komga-"))

        // 名字里全是符号时要退化成只有种类前缀
        let symbols = HostedServer.makeID(kind: .kavita, name: "！！", existing: [])
        #expect(ModelValidation.isValidSourceID(symbols))
        #expect(symbols == "kavita")
    }

    @Test("标识去重：同名服务器加序号，且第二个也合法")
    func deduplicatesIdentifier() {
        let first = HostedServer.makeID(kind: .komga, name: "NAS", existing: [])
        #expect(first == "komga-nas")
        let second = HostedServer.makeID(kind: .komga, name: "NAS", existing: [first])
        #expect(second == "komga-nas-2")
        #expect(ModelValidation.isValidSourceID(second))
        let third = HostedServer.makeID(kind: .komga, name: "NAS", existing: [first, second])
        #expect(third == "komga-nas-3")
    }

    @Test("超长名字派生出的标识不超过 64 字符（否则 SourceID 校验不过）")
    func truncatesLongIdentifier() {
        let id = HostedServer.makeID(
            kind: .kavita,
            name: String(repeating: "a", count: 200),
            existing: []
        )
        #expect(id.count <= 64)
        #expect(ModelValidation.isValidSourceID(id))

        // 去重后缀也不能把它顶出上限
        let existing = Set([id])
        let next = HostedServer.makeID(
            kind: .kavita,
            name: String(repeating: "a", count: 200),
            existing: existing
        )
        #expect(next.count <= 64)
        #expect(ModelValidation.isValidSourceID(next))
        #expect(next != id)
    }

    @Test("名称里的连字符被折叠，首尾不留连字符")
    func collapsesDashes() {
        let id = HostedServer.makeID(kind: .komga, name: "-A  --  B-", existing: [])
        #expect(id == "komga-a-b")
        #expect(ModelValidation.isValidSourceID(id))
    }

    @Test("凭据判定：只有密钥或用户名都算「配了凭据」")
    func detectsCredentials() {
        let base = HostedServer(id: "komga-a", kind: .komga, name: "A", baseURL: "https://a.com")
        #expect(base.hasCredentials == false)

        var withKey = base
        withKey.apiKey = "  "
        #expect(withKey.hasCredentials == false)
        withKey.apiKey = "secret"
        #expect(withKey.hasCredentials)

        var withUser = base
        withUser.username = "me"
        #expect(withUser.hasCredentials)
    }

    @Test("来源种类映射正确（界面据此选图标）")
    func mapsSourceKind() {
        let komga = HostedServer(id: "k1", kind: .komga, name: "A", baseURL: "https://a.com")
        let kavita = HostedServer(id: "k2", kind: .kavita, name: "B", baseURL: "https://b.com")
        #expect(komga.sourceKind == .komga)
        #expect(kavita.sourceKind == .kavita)
        #expect(komga.sourceID == SourceID("k1"))
    }
}

// MARK: - 存储

@Suite("服务器配置存储")
struct ServerStoreTests {

    private func makeStore() throws -> (ServerStore, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let store = ServerStore(fileURL: root.appendingPathComponent("Servers.json"))
        return (store, root)
    }

    private func server(_ id: String, name: String = "NAS") -> HostedServer {
        HostedServer(id: id, kind: .komga, name: name, baseURL: "https://nas.local:25600", apiKey: "secret")
    }

    @Test("添加 / 查询 / 更新 / 删除")
    func basicCRUD() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        #expect(store.isEmpty())
        try store.add(server("komga-nas"))
        #expect(store.all().count == 1)
        #expect(store.server(id: "komga-nas")?.name == "NAS")
        #expect(store.sourceIDs() == [SourceID("komga-nas")])

        var updated = try #require(store.server(id: "komga-nas"))
        updated.name = "书房 NAS"
        updated.baseURL = "https://nas2.local:25600/"
        try store.update(updated)
        #expect(store.server(id: "komga-nas")?.name == "书房 NAS")
        #expect(store.server(id: "komga-nas")?.normalizedBaseURL == "https://nas2.local:25600")

        #expect(try store.remove(id: "komga-nas"))
        #expect(store.all().isEmpty)
        #expect(try store.remove(id: "komga-nas") == false)
        // 删不存在的返回 false 而不是抛错
    }

    @Test("重复标识拒绝添加，且不会破坏已有数据")
    func rejectsDuplicate() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.add(server("komga-nas"))
        #expect(throws: AppError.invalidInput("标识已存在：komga-nas")) {
            try store.add(server("komga-nas", name: "另一台"))
        }
        #expect(store.all().count == 1)
        #expect(store.server(id: "komga-nas")?.name == "NAS")
    }

    @Test("非法标识拒绝添加")
    func rejectsInvalidIdentifier() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }
        #expect(throws: AppError.invalidInput("服务器标识不合法")) {
            try store.add(server("含中文"))
        }
        #expect(store.isEmpty())
    }

    @Test("更新不存在的服务器报 notFound")
    func updateMissingThrows() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }
        #expect(throws: AppError.notFound("服务器：komga-x")) {
            try store.update(server("komga-x"))
        }
    }

    @Test("落盘后能重新读出来（含中文名与凭据）")
    func persistsAcrossInstances() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }
        let file = root.appendingPathComponent("Servers.json")

        let first = ServerStore(fileURL: file)
        try first.add(server("komga-nas", name: "书房 NAS"))

        let second = ServerStore(fileURL: file)
        #expect(second.all().count == 1)
        #expect(second.server(id: "komga-nas")?.name == "书房 NAS")
        #expect(second.server(id: "komga-nas")?.apiKey == "secret")
    }

    @Test("配置文件损坏时不崩，也不覆盖：改名备份后当空处理")
    func toleratesCorruptFile() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }
        let file = root.appendingPathComponent("Servers.json")
        try Data("这不是 JSON".utf8).write(to: file)

        let store = ServerStore(fileURL: file)
        #expect(store.isEmpty())

        let backup = file.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        // 备份内容是原始字节，用户可以手工找回
        #expect(try Data(contentsOf: backup) == Data("这不是 JSON".utf8))

        // 之后仍能正常写入
        try store.add(server("komga-nas"))
        #expect(store.all().count == 1)
    }

    @Test("清空全部返回条数")
    func removeAllCounts() throws {
        let (store, root) = try makeStore()
        defer { TestFileSystem.remove(root) }

        try store.add(server("komga-a"))
        try store.add(server("komga-b"))
        #expect(try store.removeAll() == 2)
        #expect(store.isEmpty())
        #expect(try store.removeAll() == 0)
    }
}
