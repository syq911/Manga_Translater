//
//  DatabaseLibraryStore.swift
//  AppDatabase
//
//  书架持久化的 GRDB 实现。
//
//  **为什么用「查询列 + JSON payload」而不是逐列映射**：
//  - 逐列映射需要读多列窄表（`row["a"]`、`row["b"]`…），对 GRDB 的取值 API
//    形态依赖较重；本文件只使用最稳定的四个入口：
//    `db.execute(sql:arguments:)`、`String.fetchOne/fetchAll`、`Int.fetchOne`
//    以及自己的 JSON 编解码。接口面窄 = 不容易因库升级/取值歧义而产生编译问题。
//  - 模型演进时（比如给 `Manga` 加字段）**不需要写迁移**：payload 里自然带上。
//  - 仍然保留真正需要 SQL 能力的列（排序、筛选、置顶、清理），并建了索引。
//
//  一致性策略：payload 是**唯一事实来源**；查询列只是它的投影，任何写入都在
//  同一个事务里同时更新两者，避免出现"列与 payload 不一致"的中间态。
//

import Foundation
import GRDB
import AppCore

/// 表名与列名常量（迁移与实现共用，避免两处写错字符串）。
enum LibraryTable {
    static let entries = "library_entry"
    static let history = "reading_history"
    static let categories = "library_category"
}

/// 书架条目表结构（供迁移引用）。
struct LibraryEntryRecord {
    static let tableName = LibraryTable.entries
}

/// 阅读历史表结构（供迁移引用）。
struct ReadingHistoryRecord {
    static let tableName = LibraryTable.history
}

/// 分类表结构（供迁移引用）。
struct LibraryCategoryRecord {
    static let tableName = LibraryTable.categories
}

/// 书架持久化实现。
public final class DatabaseLibraryStore: LibraryStoring, @unchecked Sendable {

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: 书架

    @discardableResult
    public func save(_ entry: LibraryEntry) throws -> LibraryEntry {
        let payload = try Self.encode(entry)
        try database.queue.write { db in
            // 条目引用了一个尚未登记的分类时自动补建，
            // 否则会出现「条目指向不存在的分类」的孤立引用。
            try Self.ensureCategoryExists(db, id: entry.categoryID)
            try db.execute(
                sql: """
                INSERT INTO \(LibraryTable.entries)
                    (manga_id, source_id, title, added_at, last_read_at, is_pinned, category_id, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(manga_id) DO UPDATE SET
                    source_id = excluded.source_id,
                    title = excluded.title,
                    last_read_at = excluded.last_read_at,
                    is_pinned = excluded.is_pinned,
                    category_id = excluded.category_id,
                    payload = excluded.payload
                """,
                arguments: [
                    entry.id,
                    entry.manga.sourceID.rawValue,
                    entry.manga.title,
                    entry.addedAt.timeIntervalSince1970,
                    entry.lastReadAt?.timeIntervalSince1970,
                    entry.isPinned,
                    entry.categoryID,
                    payload,
                ]
            )
        }
        return entry
    }

    public func entry(mangaID: String) throws -> LibraryEntry? {
        let payload: String? = try database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payload FROM \(LibraryTable.entries) WHERE manga_id = ?",
                arguments: [mangaID]
            )
        }
        guard let payload else { return nil }
        return try Self.decodeEntry(payload)
    }

    public func entries(sortedBy order: LibrarySortOrder, categoryID: String?) throws -> [LibraryEntry] {
        var sql = "SELECT payload FROM \(LibraryTable.entries)"
        if categoryID != nil {
            sql += " WHERE category_id = ?"
        }

        // 置顶始终优先，其余按所选字段排序
        switch order {
        case .lastRead:
            sql += " ORDER BY is_pinned DESC, (last_read_at IS NULL) ASC, last_read_at DESC, added_at DESC"
        case .title:
            sql += " ORDER BY is_pinned DESC, title COLLATE NOCASE ASC, added_at DESC"
        case .recentlyAdded:
            sql += " ORDER BY is_pinned DESC, added_at DESC"
        }

        let payloads: [String] = try database.queue.read { db in
            if let categoryID {
                return try String.fetchAll(db, sql: sql, arguments: [categoryID])
            }
            return try String.fetchAll(db, sql: sql)
        }
        return try payloads.map(Self.decodeEntry)
    }

    public func contains(mangaID: String) throws -> Bool {
        try database.queue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(LibraryTable.entries) WHERE manga_id = ?",
                arguments: [mangaID]
            )
            return (count ?? 0) > 0
        }
    }

    public func count() throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(LibraryTable.entries)") ?? 0
        }
    }

    @discardableResult
    public func remove(mangaID: String) throws -> Bool {
        try database.queue.write { db in
            let existed = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(LibraryTable.entries) WHERE manga_id = ?",
                arguments: [mangaID]
            ) ?? 0) > 0
            guard existed else { return false }

            try db.execute(
                sql: "DELETE FROM \(LibraryTable.entries) WHERE manga_id = ?",
                arguments: [mangaID]
            )
            // 条目删除时连带清理它的历史，避免孤儿数据
            try db.execute(
                sql: "DELETE FROM \(LibraryTable.history) WHERE manga_id = ?",
                arguments: [mangaID]
            )
            return true
        }
    }

    @discardableResult
    public func removeAll() throws -> Int {
        try database.queue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(LibraryTable.entries)") ?? 0
            try db.execute(sql: "DELETE FROM \(LibraryTable.entries)")
            try db.execute(sql: "DELETE FROM \(LibraryTable.history)")
            return count
        }
    }

    // MARK: 阅读进度

    public func updateProgress(
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        at date: Date
    ) throws {
        guard pageIndex >= 0 else { throw LibraryStoreError.invalidPageIndex(pageIndex) }

        try database.queue.write { db in
            let payload: String? = try String.fetchOne(
                db,
                sql: "SELECT payload FROM \(LibraryTable.entries) WHERE manga_id = ?",
                arguments: [mangaID]
            )
            guard let payload else { throw LibraryStoreError.entryNotFound(mangaID) }

            var entry = try Self.decodeEntry(payload)
            entry.lastReadChapterID = chapterID
            entry.lastReadPageIndex = pageIndex
            entry.lastReadAt = date

            try db.execute(
                sql: """
                UPDATE \(LibraryTable.entries)
                   SET payload = ?, last_read_at = ?, category_id = ?, is_pinned = ?
                 WHERE manga_id = ?
                """,
                arguments: [
                    try Self.encode(entry),
                    date.timeIntervalSince1970,
                    entry.categoryID,
                    entry.isPinned,
                    mangaID,
                ]
            )

            try Self.upsertHistory(
                db: db,
                mangaID: mangaID,
                chapterID: chapterID,
                chapterName: chapterName,
                pageIndex: pageIndex,
                date: date
            )
        }
    }

    // MARK: 组织

    public func setPinned(mangaID: String, isPinned: Bool) throws {
        try mutateEntry(mangaID: mangaID) { $0.isPinned = isPinned }
    }

    public func setCategory(mangaID: String, categoryID: String?) throws {
        try database.queue.write { db in
            try Self.ensureCategoryExists(db, id: categoryID)
        }
        try mutateEntry(mangaID: mangaID) { $0.categoryID = categoryID }
    }

    public func setUnreadCount(mangaID: String, count: Int) throws {
        try mutateEntry(mangaID: mangaID) { $0.unreadCount = max(0, count) }
    }

    // MARK: 分类

    public func categories() throws -> [LibraryCategory] {
        try database.queue.read { db in
            try Self.fetchCategories(db)
        }
    }

    @discardableResult
    public func createCategory(name: String) throws -> LibraryCategory {
        let clean = ModelValidation.sanitizeCategoryName(name)
        guard !clean.isEmpty else { throw LibraryStoreError.invalidCategoryName(name) }

        return try database.queue.write { db in
            try Self.assertNameAvailable(db, name: clean, excludingID: nil)
            let nextOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM \(LibraryTable.categories)"
            ) ?? 0
            let category = LibraryCategory(name: clean, sortOrder: nextOrder)
            try db.execute(
                sql: """
                INSERT INTO \(LibraryTable.categories) (id, name, sort_order, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [category.id, category.name, category.sortOrder, Date().timeIntervalSince1970]
            )
            return category
        }
    }

    @discardableResult
    public func renameCategory(id: String, to name: String) throws -> LibraryCategory {
        let clean = ModelValidation.sanitizeCategoryName(name)
        guard !clean.isEmpty else { throw LibraryStoreError.invalidCategoryName(name) }

        return try database.queue.write { db in
            guard var current = try Self.category(db, id: id) else {
                throw LibraryStoreError.categoryNotFound(id)
            }
            try Self.assertNameAvailable(db, name: clean, excludingID: id)
            try db.execute(
                sql: "UPDATE \(LibraryTable.categories) SET name = ? WHERE id = ?",
                arguments: [clean, id]
            )
            current.name = clean
            return current
        }
    }

    @discardableResult
    public func deleteCategory(id: String) throws -> Int {
        try database.queue.write { db in
            guard try Self.category(db, id: id) != nil else {
                throw LibraryStoreError.categoryNotFound(id)
            }
            // 先让条目移出分类，再删分类；两步在同一事务内。
            try db.execute(
                sql: "UPDATE \(LibraryTable.entries) SET category_id = NULL WHERE category_id = ?",
                arguments: [id]
            )
            let affected = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            try db.execute(
                sql: "DELETE FROM \(LibraryTable.categories) WHERE id = ?",
                arguments: [id]
            )
            return affected
        }
    }

    public func reorderCategories(_ orderedIDs: [String]) throws {
        try database.queue.write { db in
            let existing = try Self.fetchCategories(db)
            var ordered: [String] = []
            for id in orderedIDs where existing.contains(where: { $0.id == id }) {
                if !ordered.contains(id) { ordered.append(id) }
            }
            // 未列出的分类保持原有相对顺序，排在后面
            for category in existing where !ordered.contains(category.id) {
                ordered.append(category.id)
            }
            for (index, id) in ordered.enumerated() {
                try db.execute(
                    sql: "UPDATE \(LibraryTable.categories) SET sort_order = ? WHERE id = ?",
                    arguments: [index, id]
                )
            }
        }
    }

    private static func fetchCategories(_ db: Database) throws -> [LibraryCategory] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, sort_order FROM \(LibraryTable.categories)
             ORDER BY sort_order ASC, name COLLATE NOCASE ASC
            """
        )
        return rows.map { row in
            LibraryCategory(
                id: row["id"],
                name: row["name"],
                sortOrder: row["sort_order"]
            )
        }
    }

    private static func category(_ db: Database, id: String) throws -> LibraryCategory? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, name, sort_order FROM \(LibraryTable.categories) WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        return LibraryCategory(id: row["id"], name: row["name"], sortOrder: row["sort_order"])
    }

    /// 分类名查重：忽略大小写与首尾/连续空白。
    private static func assertNameAvailable(_ db: Database, name: String, excludingID: String?) throws {
        let key = ModelValidation.categoryNameKey(name)
        let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM \(LibraryTable.categories)")
        for row in rows {
            let otherID: String = row["id"]
            if let excludingID, otherID == excludingID { continue }
            let otherName: String = row["name"]
            if ModelValidation.categoryNameKey(otherName) == key {
                throw LibraryStoreError.duplicateCategoryName(name)
            }
        }
    }

    /// 确保给定分类 id 已在分类表里；缺失则按 id 同名补建（沿用旧数据的习惯：
    /// 早期版本用分类名当 id）。`nil` / 空串不做任何事。
    private static func ensureCategoryExists(_ db: Database, id: String?) throws {
        guard let id, !id.isEmpty else { return }
        if try Self.category(db, id: id) != nil { return }
        let nextOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM \(LibraryTable.categories)"
        ) ?? 0
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO \(LibraryTable.categories) (id, name, sort_order, created_at)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [id, id, nextOrder, Date().timeIntervalSince1970]
        )
    }

    // MARK: 阅读历史

    public func recordHistory(
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        at date: Date
    ) throws {
        guard pageIndex >= 0 else { throw LibraryStoreError.invalidPageIndex(pageIndex) }
        try database.queue.write { db in
            try Self.upsertHistory(
                db: db,
                mangaID: mangaID,
                chapterID: chapterID,
                chapterName: chapterName,
                pageIndex: pageIndex,
                date: date
            )
        }
    }

    public func recentHistory(limit: Int) throws -> [ReadingHistoryEntry] {
        guard limit > 0 else { throw LibraryStoreError.invalidLimit(limit) }
        let payloads: [String] = try database.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT payload FROM \(LibraryTable.history) ORDER BY read_at DESC LIMIT ?",
                arguments: [limit]
            )
        }
        return try payloads.map(Self.decodeHistory)
    }

    public func history(mangaID: String) throws -> [ReadingHistoryEntry] {
        let payloads: [String] = try database.queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT payload FROM \(LibraryTable.history)
                 WHERE manga_id = ? ORDER BY read_at DESC
                """,
                arguments: [mangaID]
            )
        }
        return try payloads.map(Self.decodeHistory)
    }

    @discardableResult
    public func removeHistory(mangaID: String, chapterID: String) throws -> Bool {
        let id = ReadingHistoryEntry.makeID(mangaID: mangaID, chapterID: chapterID)
        return try database.queue.write { db in
            let existed = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(LibraryTable.history) WHERE id = ?",
                arguments: [id]
            ) ?? 0) > 0
            guard existed else { return false }
            try db.execute(sql: "DELETE FROM \(LibraryTable.history) WHERE id = ?", arguments: [id])
            return true
        }
    }

    @discardableResult
    public func clearHistory() throws -> Int {
        try database.queue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(LibraryTable.history)") ?? 0
            try db.execute(sql: "DELETE FROM \(LibraryTable.history)")
            return count
        }
    }

    @discardableResult
    public func pruneHistory(keep: Int) throws -> Int {
        guard keep >= 0 else { throw LibraryStoreError.invalidLimit(keep) }
        return try database.queue.write { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(LibraryTable.history)") ?? 0
            guard total > keep else { return 0 }

            try db.execute(
                sql: """
                DELETE FROM \(LibraryTable.history) WHERE id NOT IN (
                    SELECT id FROM \(LibraryTable.history) ORDER BY read_at DESC LIMIT ?
                )
                """,
                arguments: [keep]
            )
            return total - keep
        }
    }

    // MARK: 内部

    /// 读出条目、就地修改、写回（payload 与投影列同一个 UPDATE）。
    private func mutateEntry(mangaID: String, _ mutate: (inout LibraryEntry) -> Void) throws {
        try database.queue.write { db in
            let payload: String? = try String.fetchOne(
                db,
                sql: "SELECT payload FROM \(LibraryTable.entries) WHERE manga_id = ?",
                arguments: [mangaID]
            )
            guard let payload else { throw LibraryStoreError.entryNotFound(mangaID) }

            var entry = try Self.decodeEntry(payload)
            mutate(&entry)

            try db.execute(
                sql: """
                UPDATE \(LibraryTable.entries)
                   SET payload = ?, title = ?, last_read_at = ?, is_pinned = ?, category_id = ?
                 WHERE manga_id = ?
                """,
                arguments: [
                    try Self.encode(entry),
                    entry.manga.title,
                    entry.lastReadAt?.timeIntervalSince1970,
                    entry.isPinned,
                    entry.categoryID,
                    mangaID,
                ]
            )
        }
    }

    private static func upsertHistory(
        db: Database,
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        date: Date
    ) throws {
        let entry = ReadingHistoryEntry(
            mangaID: mangaID,
            chapterID: chapterID,
            chapterName: chapterName,
            pageIndex: pageIndex,
            readAt: date
        )
        let payload = try encodeHistory(entry)

        try db.execute(
            sql: """
            INSERT INTO \(LibraryTable.history)
                (id, manga_id, chapter_id, chapter_name, page_index, read_at, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                chapter_name = excluded.chapter_name,
                page_index = excluded.page_index,
                read_at = excluded.read_at,
                payload = excluded.payload
            """,
            arguments: [
                entry.id,
                mangaID,
                chapterID,
                chapterName,
                max(0, pageIndex),
                date.timeIntervalSince1970,
                payload,
            ]
        )
    }

    // MARK: 编解码

    static func encode(_ entry: LibraryEntry) throws -> String {
        do {
            let data = try JSONEncoder().encode(entry)
            guard let text = String(data: data, encoding: .utf8) else {
                throw LibraryStoreError.corruptRow(reason: "条目 JSON 无法转为 UTF-8")
            }
            return text
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            throw LibraryStoreError.corruptRow(reason: "条目编码失败：\(error.localizedDescription)")
        }
    }

    static func decodeEntry(_ payload: String) throws -> LibraryEntry {
        do {
            return try JSONDecoder().decode(LibraryEntry.self, from: Data(payload.utf8))
        } catch {
            throw LibraryStoreError.corruptRow(reason: "条目解码失败：\(error.localizedDescription)")
        }
    }

    static func encodeHistory(_ entry: ReadingHistoryEntry) throws -> String {
        do {
            let data = try JSONEncoder().encode(entry)
            guard let text = String(data: data, encoding: .utf8) else {
                throw LibraryStoreError.corruptRow(reason: "历史 JSON 无法转为 UTF-8")
            }
            return text
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            throw LibraryStoreError.corruptRow(reason: "历史编码失败：\(error.localizedDescription)")
        }
    }

    static func decodeHistory(_ payload: String) throws -> ReadingHistoryEntry {
        do {
            return try JSONDecoder().decode(ReadingHistoryEntry.self, from: Data(payload.utf8))
        } catch {
            throw LibraryStoreError.corruptRow(reason: "历史解码失败：\(error.localizedDescription)")
        }
    }
}
