//
//  LibraryView.swift
//  MangaTranslater
//
//  书架：收藏的作品、阅读进度、排序与删除；可直接从书架导入本地文件。
//
//  数据来自 `LibraryStoring`（正常为 GRDB；不可用时降级为内存，页面会提示）。
//

import SwiftUI
import UniformTypeIdentifiers
import AppCore
import SourceEngine
import AppDatabase

struct LibraryView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var entries: [LibraryEntry] = []
    @State private var categories: [LibraryCategory] = []
    /// nil = 显示全部作品。
    @State private var selectedCategoryID: String?
    @State private var sortOrder: LibrarySortOrder = .lastRead
    @State private var showsImporter = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }
            .navigationTitle(L("tab.library"))
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showsImporter,
                allowedContentTypes: LocalBooksView.importableTypes,
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .onAppear(perform: reload)
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: 子视图

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L("library.empty.title"), systemImage: "books.vertical")
        } description: {
            Text(L("library.empty.body"))
        } actions: {
            Button("导入本地文件") { showsImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var entryList: some View {
        List {
            if !environment.isLibraryPersistent {
                Section {
                    Label("书架当前无法持久化（数据库不可用），本次会话结束后会清空。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }

            ForEach(entries) { entry in
                NavigationLink {
                    ReaderView(
                        manga: entry.manga,
                        readingSource: environment.readingSource(for: entry.manga)
                    )
                } label: {
                    row(for: entry)
                }
                .contextMenu { rowMenu(for: entry) }
            }
            .onDelete(perform: delete)
        }
    }

    /// 长按菜单：分类归属与置顶（相比滑动删除，这些操作更适合放在菜单里）。
    @ViewBuilder
    private func rowMenu(for entry: LibraryEntry) -> some View {
        Menu {
            Button {
                move(entry, to: nil)
            } label: {
                Label("移出分类", systemImage: entry.categoryID == nil ? "checkmark" : "folder.badge.minus")
            }
            ForEach(categories) { category in
                Button {
                    move(entry, to: category.id)
                } label: {
                    Label(
                        category.name,
                        systemImage: entry.categoryID == category.id ? "checkmark" : "folder"
                    )
                }
            }
        } label: {
            Label("移动到分类", systemImage: "folder")
        }

        Button {
            togglePin(entry)
        } label: {
            Label(entry.isPinned ? "取消置顶" : "置顶", systemImage: entry.isPinned ? "pin.slash" : "pin")
        }

        Button(role: .destructive) {
            remove(entry)
        } label: {
            Label("移出书架", systemImage: "trash")
        }
    }

    private func row(for entry: LibraryEntry) -> some View {
        HStack(spacing: 12) {
            CoverThumbnailView(manga: entry.manga)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(entry.manga.title)
                        .lineLimit(2)
                }
                Text(progressText(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    selectedCategoryID = nil
                    reload()
                } label: {
                    Label("全部作品", systemImage: selectedCategoryID == nil ? "checkmark" : "books.vertical")
                }
                if !categories.isEmpty {
                    Divider()
                    ForEach(categories) { category in
                        Button {
                            selectedCategoryID = category.id
                            reload()
                        } label: {
                            Label(
                                category.name,
                                systemImage: selectedCategoryID == category.id ? "checkmark" : "folder"
                            )
                        }
                    }
                }
                Divider()
                NavigationLink {
                    CategoryManagerView()
                } label: {
                    Label("管理分类…", systemImage: "folder.badge.gearshape")
                }
            } label: {
                Label(categoryFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("排序", selection: $sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            .onChange(of: sortOrder) { _, _ in reload() }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showsImporter = true
            } label: {
                Label("导入", systemImage: "plus")
            }
        }
    }

    private var categoryFilterLabel: String {
        guard let selectedCategoryID else { return "全部作品" }
        return categories.first { $0.id == selectedCategoryID }?.name ?? "全部作品"
    }

    // MARK: 行为

    private func progressText(for entry: LibraryEntry) -> String {
        guard entry.lastReadChapterID != nil else { return "尚未开始阅读" }
        let page = (entry.lastReadPageIndex ?? 0) + 1
        if let readAt = entry.lastReadAt {
            return "读到第 \(page) 页 · \(Self.relativeFormatter.localizedString(for: readAt, relativeTo: Date()))"
        }
        return "读到第 \(page) 页"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func reload() {
        categories = (try? environment.libraryStore.categories()) ?? []
        // 分类可能已被删除（在管理页或别处），此时回退到「全部作品」，
        // 否则会停在一个空列表上让用户以为书架坏了。
        if let selectedCategoryID, !categories.contains(where: { $0.id == selectedCategoryID }) {
            self.selectedCategoryID = nil
        }
        entries = (try? environment.libraryStore.entries(sortedBy: sortOrder, categoryID: selectedCategoryID)) ?? []
    }

    private func move(_ entry: LibraryEntry, to categoryID: String?) {
        do {
            try environment.libraryStore.setCategory(mangaID: entry.manga.id, categoryID: categoryID)
            reload()
        } catch {
            message = (error as? LibraryStoreError)?.message ?? error.localizedDescription
        }
    }

    private func togglePin(_ entry: LibraryEntry) {
        do {
            try environment.libraryStore.setPinned(mangaID: entry.manga.id, isPinned: !entry.isPinned)
            reload()
        } catch {
            message = (error as? LibraryStoreError)?.message ?? error.localizedDescription
        }
    }

    private func remove(_ entry: LibraryEntry) {
        _ = try? environment.libraryStore.remove(mangaID: entry.manga.id)
        reload()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where entries.indices.contains(index) {
            let entry = entries[index]
            _ = try? environment.libraryStore.remove(mangaID: entry.manga.id)
        }
        reload()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            var succeeded = 0
            var failures: [String] = []

            for url in urls {
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                do {
                    let imported = try environment.localSource.importBook(from: url)
                    environment.addToLibrary(imported.manga)
                    succeeded += 1
                } catch {
                    let reason = (error as? LocalSourceError)?.message ?? error.localizedDescription
                    failures.append("\(url.lastPathComponent)：\(reason)")
                }
            }

            reload()
            message = failures.isEmpty
                ? "已导入 \(succeeded) 个文件。"
                : "成功 \(succeeded) 个，失败 \(failures.count) 个：\n" + failures.joined(separator: "\n")

        case let .failure(error):
            message = "选择文件失败：\(error.localizedDescription)"
        }
    }
}

#Preview {
    LibraryView()
        .environment(AppEnvironment.makeDefault())
}
