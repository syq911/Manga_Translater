//
//  InMemoryLibraryStore.swift
//  AppDatabase
//
//  内存版书架实现（不依赖 GRDB）。
//
//  两个用途：
//  1. **降级兜底**：磁盘数据库打不开时（磁盘满、沙盒异常、迁移失败），
//     App 仍可用内存书架运行，只是不持久化 —— 而不是启动即崩；
//  2. **协议测试的第二实现**：同一批断言跑在两个实现上，
//     能验证 `LibraryStoring` 的语义是否被一致实现。
//
//  语义与 `DatabaseLibraryStore` 保持一致（排序规则、连带删除、错误类型）。
//

import Foundation
import AppCore

/// 内存书架。
public final class InMemoryLibraryStore: LibraryStoring, @unchecked Sendable {

    private var entries: [String: LibraryEntry] = [:]
    private var history: [String: ReadingHistoryEntry] = [:]
    private var storedCategories: [String: LibraryCategory] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: 书架

    @discardableResult
    public func save(_ entry: LibraryEntry) throws -> LibraryEntry {
        lock.lock()
        // 与 GRDB 实现保持一致：引用未登记的分类时自动补建，避免孤立引用
        if let categoryID = entry.categoryID, !categoryID.isEmpty, storedCategories[categoryID] == nil {
            let nextOrder = (storedCategories.values.map(\.sortOrder).max() ?? -1) + 1
            storedCategories[categoryID] = LibraryCategory(id: categoryID, name: categoryID, sortOrder: nextOrder)
        }
        entries[entry.id] = entry
        lock.unlock()
        return entry
    }

    public func entry(mangaID: String) throws -> LibraryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[mangaID]
    }

    public func entries(sortedBy order: LibrarySortOrder, categoryID: String?) throws -> [LibraryEntry] {
        lock.lock()
        let all = Array(entries.values)
        lock.unlock()

        let filtered = categoryID.map { wanted in all.filter { $0.categoryID == wanted } } ?? all

        return filtered.sorted { lhs, rhs in
            // 置顶恒优先
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }

            switch order {
            case .lastRead:
                switch (lhs.lastReadAt, rhs.lastReadAt) {
                case let (l?, r?):
                    if l != r { return l > r }
                case (nil, .some):
                    return false          // 未读排在后面
                case (.some, nil):
                    return true
                case (nil, nil):
                    break
                }
                return lhs.addedAt > rhs.addedAt
            case .title:
                let comparison = lhs.manga.title.compare(rhs.manga.title, options: [.caseInsensitive])
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.addedAt > rhs.addedAt
            case .recentlyAdded:
                return lhs.addedAt > rhs.addedAt
            }
        }
    }

    public func contains(mangaID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[mangaID] != nil
    }

    public func count() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    @discardableResult
    public func remove(mangaID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries.removeValue(forKey: mangaID) != nil else { return false }
        history = history.filter { $0.value.mangaID != mangaID }
        return true
    }

    @discardableResult
    public func removeAll() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let removed = entries.count
        entries.removeAll()
        history.removeAll()
        return removed
    }

    // MARK: 进度

    public func updateProgress(
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        at date: Date
    ) throws {
        guard pageIndex >= 0 else { throw LibraryStoreError.invalidPageIndex(pageIndex) }

        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[mangaID] else {
            throw LibraryStoreError.entryNotFound(mangaID)
        }
        entry.lastReadChapterID = chapterID
        entry.lastReadPageIndex = pageIndex
        entry.lastReadAt = date
        entries[mangaID] = entry

        let record = ReadingHistoryEntry(
            mangaID: mangaID,
            chapterID: chapterID,
            chapterName: chapterName,
            pageIndex: pageIndex,
            readAt: date
        )
        history[record.id] = record
    }

    // MARK: 组织

    public func setPinned(mangaID: String, isPinned: Bool) throws {
        try mutate(mangaID) { $0.isPinned = isPinned }
    }

    public func setCategory(mangaID: String, categoryID: String?) throws {
        lock.lock()
        if let categoryID, !categoryID.isEmpty, storedCategories[categoryID] == nil {
            let nextOrder = (storedCategories.values.map(\.sortOrder).max() ?? -1) + 1
            storedCategories[categoryID] = LibraryCategory(id: categoryID, name: categoryID, sortOrder: nextOrder)
        }
        lock.unlock()
        try mutate(mangaID) { $0.categoryID = categoryID }
    }

    public func setUnreadCount(mangaID: String, count: Int) throws {
        try mutate(mangaID) { $0.unreadCount = max(0, count) }
    }

    // MARK: 分类

    public func categories() throws -> [LibraryCategory] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sortedCategories(storedCategories.values)
    }

    @discardableResult
    public func createCategory(name: String) throws -> LibraryCategory {
        let clean = ModelValidation.sanitizeCategoryName(name)
        guard !clean.isEmpty else { throw LibraryStoreError.invalidCategoryName(name) }

        lock.lock()
        defer { lock.unlock() }
        try Self.assertNameAvailable(storedCategories.values, name: clean, excludingID: nil)
        let nextOrder = (storedCategories.values.map(\.sortOrder).max() ?? -1) + 1
        let category = LibraryCategory(name: clean, sortOrder: nextOrder)
        storedCategories[category.id] = category
        return category
    }

    @discardableResult
    public func renameCategory(id: String, to name: String) throws -> LibraryCategory {
        let clean = ModelValidation.sanitizeCategoryName(name)
        guard !clean.isEmpty else { throw LibraryStoreError.invalidCategoryName(name) }

        lock.lock()
        defer { lock.unlock() }
        guard var current = storedCategories[id] else {
            throw LibraryStoreError.categoryNotFound(id)
        }
        try Self.assertNameAvailable(storedCategories.values, name: clean, excludingID: id)
        current.name = clean
        storedCategories[id] = current
        return current
    }

    @discardableResult
    public func deleteCategory(id: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard storedCategories[id] != nil else {
            throw LibraryStoreError.categoryNotFound(id)
        }
        var affected = 0
        for (key, var entry) in entries where entry.categoryID == id {
            entry.categoryID = nil
            entries[key] = entry
            affected += 1
        }
        storedCategories[id] = nil
        return affected
    }

    public func reorderCategories(_ orderedIDs: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = Self.sortedCategories(storedCategories.values)
        var ordered: [String] = []
        for id in orderedIDs where existing.contains(where: { $0.id == id }) {
            if !ordered.contains(id) { ordered.append(id) }
        }
        for category in existing where !ordered.contains(category.id) {
            ordered.append(category.id)
        }
        for (index, id) in ordered.enumerated() {
            storedCategories[id]?.sortOrder = index
        }
    }

    private static func sortedCategories<S: Sequence>(_ values: S) -> [LibraryCategory]
    where S.Element == LibraryCategory {
        values.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.compare(rhs.name, options: .caseInsensitive) == .orderedAscending
        }
    }

    private static func assertNameAvailable<S: Sequence>(
        _ values: S,
        name: String,
        excludingID: String?
    ) throws where S.Element == LibraryCategory {
        let key = ModelValidation.categoryNameKey(name)
        for category in values {
            if let excludingID, category.id == excludingID { continue }
            if ModelValidation.categoryNameKey(category.name) == key {
                throw LibraryStoreError.duplicateCategoryName(name)
            }
        }
    }

    // MARK: 历史

    public func recordHistory(
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        at date: Date
    ) throws {
        guard pageIndex >= 0 else { throw LibraryStoreError.invalidPageIndex(pageIndex) }
        lock.lock()
        defer { lock.unlock() }
        let record = ReadingHistoryEntry(
            mangaID: mangaID,
            chapterID: chapterID,
            chapterName: chapterName,
            pageIndex: pageIndex,
            readAt: date
        )
        history[record.id] = record
    }

    public func recentHistory(limit: Int) throws -> [ReadingHistoryEntry] {
        guard limit > 0 else { throw LibraryStoreError.invalidLimit(limit) }
        return Array(sortedHistory().prefix(limit))
    }

    public func history(mangaID: String) throws -> [ReadingHistoryEntry] {
        sortedHistory().filter { $0.mangaID == mangaID }
    }

    @discardableResult
    public func removeHistory(mangaID: String, chapterID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let id = ReadingHistoryEntry.makeID(mangaID: mangaID, chapterID: chapterID)
        return history.removeValue(forKey: id) != nil
    }

    @discardableResult
    public func clearHistory() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = history.count
        history.removeAll()
        return count
    }

    @discardableResult
    public func pruneHistory(keep: Int) throws -> Int {
        guard keep >= 0 else { throw LibraryStoreError.invalidLimit(keep) }
        lock.lock()
        defer { lock.unlock() }
        let ordered = history.values.sorted { $0.readAt > $1.readAt }
        guard ordered.count > keep else { return 0 }
        let doomed = ordered.dropFirst(keep)
        for record in doomed { history.removeValue(forKey: record.id) }
        return doomed.count
    }

    // MARK: 内部

    private func mutate(_ mangaID: String, _ change: (inout LibraryEntry) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[mangaID] else {
            throw LibraryStoreError.entryNotFound(mangaID)
        }
        change(&entry)
        entries[mangaID] = entry
    }

    private func sortedHistory() -> [ReadingHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return history.values.sorted { $0.readAt > $1.readAt }
    }
}
