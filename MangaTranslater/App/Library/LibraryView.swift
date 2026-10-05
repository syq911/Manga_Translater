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
                    ReaderView(manga: entry.manga)
                } label: {
                    row(for: entry)
                }
            }
            .onDelete(perform: delete)
        }
    }

    private func row(for entry: LibraryEntry) -> some View {
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
        .padding(.vertical, 2)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
        entries = (try? environment.libraryStore.entries(sortedBy: sortOrder, categoryID: nil)) ?? []
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
