//
//  LocalBooksView.swift
//  MangaTranslater
//
//  「本地文件」：列出文件系统里的 CBZ / ZIP，支持导入与直接阅读。
//
//  本地作品的事实来源是文件系统（不是数据库），所以这里每次进入都重新扫描；
//  点进去阅读时会自动加入书架。
//

import SwiftUI
import UniformTypeIdentifiers
import AppCore
import SourceEngine

struct LocalBooksView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var books: [Manga] = []
    /// 作品 → 章节数。**在 reload 时一次算好**，不在每行渲染时重复解析 ZIP。
    @State private var chapterCounts: [String: Int] = [:]
    @State private var showsImporter = false
    @State private var message: String?
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                if books.isEmpty {
                    Text("还没有导入任何本地文件。支持 CBZ / ZIP。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(books, id: \.id) { book in
                        NavigationLink {
                            ReaderView(manga: book)
                        } label: {
                            row(for: book)
                        }
                    }
                }
            } header: {
                Text("本地文件")
            } footer: {
                Text("导入后会复制到 App 内部目录，原文件移动或删除都不影响阅读。")
            }
        }
        .navigationTitle("本地文件")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsImporter = true
                } label: {
                    Label("导入", systemImage: "plus")
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
        .alert("导入结果", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func row(for book: Manga) -> some View {
        HStack(spacing: 12) {
            CoverThumbnailView(manga: book)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                if let count = chapterCounts[book.id] {
                    Text("\(count) 章")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 行为

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
                    failures.append("\(url.lastPathComponent)：\((error as? LocalSourceError)?.message ?? error.localizedDescription)")
                }
            }

            Task { await reload() }
            isImporting = false
            if failures.isEmpty {
                message = "已导入 \(succeeded) 个文件。"
            } else {
                message = "成功 \(succeeded) 个，失败 \(failures.count) 个：\n" + failures.joined(separator: "\n")
            }

        case let .failure(error):
            message = "选择文件失败：\(error.localizedDescription)"
        }
    }
}
