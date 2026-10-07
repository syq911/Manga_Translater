//
//  AppDatabase.swift
//  AppDatabase
//
//  数据库打开、迁移与生命周期。
//
//  设计要点：
//  - 用 `DatabaseQueue`（单写者）而不是 `DatabasePool`：书架数据量小（百万行级以下），
//    单写者模型足够，且没有 WAL 相关的边界问题。
//  - 迁移在 `open` 时自动执行；迁移失败必须**抛出**而不是降级（宁可打不开也不要
//    带着半迁移的库跑）。
//  - 提供内存数据库入口，测试不碰磁盘。
//

import Foundation
import GRDB
import AppCore

/// 数据库位置。
public enum DatabaseLocation: Sendable {
    /// 内存数据库（测试 / 预览用）。
    case memory
    /// 磁盘文件。父目录会自动创建。
    case file(URL)
}

/// 应用数据库。
public struct AppDatabase: Sendable {

    /// 底层队列。所有读写都经由它，保证单写者语义。
    public let queue: DatabaseQueue

    /// 迁移注册表（供测试断言迁移集合）。
    public let migrator: DatabaseMigrator

    /// 打开（或创建）数据库并执行迁移。
    /// - Throws: `AppError.fileSystem`（目录/文件不可用）、`AppError.unknown`（迁移失败）
    public static func open(_ location: DatabaseLocation) throws -> AppDatabase {
        let queue: DatabaseQueue

        switch location {
        case .memory:
            queue = try DatabaseQueue()
        case let .file(url):
            do {
                let directory = url.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
            } catch {
                throw AppError.fileSystem(Copy.format("error.db.createDirectoryFailed", error.localizedDescription))
            }
            do {
                var configuration = Configuration()
                // 迁移期间遇到外键问题宁可失败，不要静默吞掉
                configuration.foreignKeysEnabled = true
                queue = try DatabaseQueue(path: url.path, configuration: configuration)
            } catch {
                throw AppError.fileSystem(Copy.format("error.db.openFailed", error.localizedDescription))
            }
        }

        var migrator = DatabaseMigrator()
        Migrations.register(on: &migrator)
        do {
            try migrator.migrate(queue)
        } catch {
            throw AppError.unknown(Copy.format("error.db.migrationFailed", error.localizedDescription))
        }

        diag("AppDatabase: 已打开数据库（\(location.description)），迁移 \(Migrations.all.count) 项")
        return AppDatabase(queue: queue, migrator: migrator)
    }

    /// 当前 schema 版本（已执行的最大迁移标识）。
    public func currentSchemaVersion() throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
        }
    }

    /// 已执行的迁移标识列表（按执行顺序）。
    public func appliedMigrations() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    /// 关闭数据库（释放文件句柄）。
    public func close() throws {
        try queue.close()
    }
}

extension DatabaseLocation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .memory: return "memory"
        case let .file(url): return url.lastPathComponent
        }
    }
}

// MARK: - 迁移

/// 数据库迁移定义。**只允许追加**，不得修改已发布的迁移。
public enum Migrations {

    /// 首次发布的 schema。
    public static let initial = "v1_initial"
    /// 分类独立成表（此前分类只是条目上的自由字符串）。
    public static let categories = "v2_categories"

    /// 全部迁移标识（按执行顺序）。新增迁移时**追加**到这里，
    /// 同时补一个 `registerMigration`。
    public static let all: [String] = [initial, categories]

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(initial) { db in
            // 书架条目：`payload` 存完整模型的 JSON（唯一事实来源），
            // 其余列是它的投影，只为排序 / 筛选 / 置顶服务并建了索引。
            // 这样给模型加字段时无需迁移；写入时两者在同一事务内更新。
            try db.create(table: LibraryEntryRecord.tableName) { table in
                table.primaryKey("manga_id", .text)
                table.column("source_id", .text).notNull()
                table.column("title", .text).notNull()
                table.column("added_at", .double).notNull()
                table.column("last_read_at", .double)
                table.column("is_pinned", .boolean).notNull().defaults(to: false)
                table.column("category_id", .text)
                table.column("payload", .text).notNull()
            }
            try db.create(
                index: "idx_library_last_read_at",
                on: LibraryEntryRecord.tableName,
                columns: ["last_read_at"]
            )
            try db.create(
                index: "idx_library_category",
                on: LibraryEntryRecord.tableName,
                columns: ["category_id"]
            )
            try db.create(
                index: "idx_library_pinned_added",
                on: LibraryEntryRecord.tableName,
                columns: ["is_pinned", "added_at"]
            )

            // 阅读历史：同一 (作品, 章节) 只保留一条（主键 = mangaID|chapterID），
            // 重复阅读更新时间与页码。
            try db.create(table: ReadingHistoryRecord.tableName) { table in
                table.primaryKey("id", .text)
                table.column("manga_id", .text).notNull()
                table.column("chapter_id", .text).notNull()
                table.column("chapter_name", .text).notNull().defaults(to: "")
                table.column("page_index", .integer).notNull().defaults(to: 0)
                table.column("read_at", .double).notNull()
                table.column("payload", .text).notNull()
            }
            try db.create(
                index: "idx_history_read_at",
                on: ReadingHistoryRecord.tableName,
                columns: ["read_at"]
            )
            try db.create(
                index: "idx_history_manga",
                on: ReadingHistoryRecord.tableName,
                columns: ["manga_id"]
            )
        }

        migrator.registerMigration(categories) { db in
            // 分类从「条目上的自由字符串」升级为独立表：
            // 这样才能存在「暂无作品的分类」，也才能重命名与排序。
            try db.create(table: LibraryCategoryRecord.tableName) { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("sort_order", .integer).notNull().defaults(to: 0)
                table.column("created_at", .double).notNull()
            }
            try db.create(
                index: "idx_category_sort",
                on: LibraryCategoryRecord.tableName,
                columns: ["sort_order", "name"]
            )

            // 回填既有数据：把条目上出现过的分类名登记为分类。
            // 这里**直接用旧分类名当 id**，于是既有的 `category_id` 引用无需改写，
            // 迁移对用户完全无感。新建的分类才会使用 UUID。
            try db.execute(
                sql: """
                INSERT INTO \(LibraryCategoryRecord.tableName) (id, name, sort_order, created_at)
                SELECT category_id, category_id, 0, ?
                  FROM \(LibraryEntryRecord.tableName)
                 WHERE category_id IS NOT NULL AND category_id <> ''
                 GROUP BY category_id
                 ORDER BY category_id
                """,
                arguments: [Date().timeIntervalSince1970]
            )
        }
    }
}
