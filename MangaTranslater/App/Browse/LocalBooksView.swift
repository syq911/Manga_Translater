//
//  LocalBooksView.swift
//  MangaTranslater
//
//  「本地文件」：列出文件系统里的 CBZ / ZIP，支持导入与直接阅读。
//
//  本地作品的事实来源是文件系统（不是数据库），所以这里每次进入都重新扫描。
//
//  **加入书架发生在导入那一刻**（见 `handleImport`），阅读本身不写书架：
//  阅读器只在作品已在书架里时才记进度，因此「点进去看」这个动作不该悄悄改变书架。
//

import SwiftUI
import UniformTypeIdentifiers
import AppCore
import SourceEngine
import AppDatabase

struct LocalBooksView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var books: [Manga] = []
    /// 作品 → 章节数。**在 reload 时一次算好**，不在每行渲染时重复解析 ZIP。
    @State private var chapterCounts: [String: Int] = [:]
    @State private var showsImporter = false
    @State private var message: String?
    @State private var isImporting = false
    /// 待确认删除的本地作品。
    ///
    /// 这是 App 里**唯一会删用户自己的文件**的操作，因此必须确认，
    /// 而且文案要写明「没有回收站」——用户对这个动作的默认预期是「进废纸篓」。
    @State private var pendingDeletion: Manga?

    var body: some View {
        List {
            Section {
                if books.isEmpty {
                    Text(L("local.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(books, id: \.id) { book in
                        NavigationLink {
                            ReaderView(
                                manga: book,
                                readingSource: environment.readingSource(for: book)
                            )
                        } label: {
                            row(for: book)
                        }
                        // 「导入的文件在 App 里删不掉」曾是个真问题：作品能移出书架，
                        // 但文件一直占着空间，用户找不到清理入口（O-9）。
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                requestDeletion(book)
                            } label: {
                                Label(L("local.delete.action"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(L("browse.section.local"))
            } footer: {
                Text(L("local.footer"))
            }
        }
        .navigationTitle(L("browse.section.local"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsImporter = true
                } label: {
                    Label(L("library.action.import"), systemImage: "plus")
                }
                .disabled(isImporting)
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .task { await reload() }
        .alert(L("local.importResult"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(
            L("local.delete.title"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("local.delete.action"), role: .destructive) {
                if let book = pendingDeletion { delete(book) }
                pendingDeletion = nil
            }
            Button(L("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(String(format: L("local.delete.message"), pendingDeletion?.title ?? ""))
        }
    }

    private func row(for book: Manga) -> some View {
        HStack(spacing: 12) {
            CoverThumbnailView(manga: book)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                if let count = chapterCounts[book.id] {
                    Text(String(format: L("local.chapterCount"), count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 行为

    /// 请求删除本地文件：按策略决定「先确认」还是「直接删」。
    private func requestDeletion(_ book: Manga) {
        if DestructiveActionPolicy.requiresConfirmation(.deleteLocalBook) {
            pendingDeletion = book
        } else {
            delete(book)
        }
    }

    /// 删除本地文件（归档 + 侧车），并从书架移出。
    ///
    /// 两步都要做：只删文件的话书架里会留一条打不开的记录；
    /// 只移出书架则文件还在占空间——而用户点这个按钮的动机就是「腾空间」。
    private func delete(_ book: Manga) {
        do {
            let removed = try environment.localSource.removeBook(mangaID: book.id)
            _ = try? environment.libraryStore.remove(mangaID: book.id)
            Task { await reload() }
            message = removed
                ? String(format: L("local.deleted"), book.title)
                : L("local.delete.notFound")
        } catch {
            message = (error as? LocalSourceError)?.message ?? error.localizedDescription
        }
    }

    /// 重新扫描本地文件。解析归档（取章节数）放到后台，避免进入页面时卡顿。
    private func reload() async {
        let source = environment.localSource
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([Manga], [String: Int]) in
            let books = (try? source.books()) ?? []
            var counts: [String: Int] = [:]
            for book in books {
                counts[book.id] = (try? source.chapters(for: book))?.count ?? 0
            }
            return (books, counts)
        }.value

        books = outcome.0
        chapterCounts = outcome.1
    }

    /// 可导入的类型：`.cbz` 在系统里没有独立 UTI，按其父类型 zip 处理。
    static var importableTypes: [UTType] {
        var types: [UTType] = []
        if let cbz = UTType(filenameExtension: "cbz") { types.append(cbz) }
        types.append(.zip)
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            isImporting = true
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
                    failures.append(
                        String(
                            format: L("library.import.failureLine"),
                            url.lastPathComponent,
                            (error as? LocalSourceError)?.message ?? error.localizedDescription
                        )
                    )
                }
            }

            Task { await reload() }
            isImporting = false
            if failures.isEmpty {
                message = String(format: L("library.import.done"), succeeded)
            } else {
                message = String(
                    format: L("library.import.partial"),
                    succeeded,
                    failures.count,
                    failures.joined(separator: "\n")
                )
            }

        case let .failure(error):
            message = String(format: L("library.import.pickFailed"), error.localizedDescription)
        }
    }
}
