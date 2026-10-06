//
//  SourceMangaDetailView.swift
//  MangaTranslater
//
//  来源作品详情：作品信息 + 章节列表 + 加入书架。
//
//  章节行直接进入阅读器（在线来源走 `RemoteReadingSource`：脚本取页列表 +
//  图片加载器取字节）。阅读进度只有作品在书架里时才记录，所以这里把
//  「加入书架」放在显眼位置。
//
//  数据来源：详情与章节各调一次契约方法；两者分别处理失败，
//  详情失败就整页失败，章节失败只在章节区提示（作品信息仍然有用）。
//

import SwiftUI
import AppCore
import SourceEngine

struct SourceMangaDetailView: View {

    let manga: Manga
    let source: InstalledSource

    @Environment(AppEnvironment.self) private var environment

    @State private var phase: Phase = .loading
    @State private var detail: Manga?
    @State private var chapters: [Chapter] = []
    @State private var chapterError: String?
    @State private var isInLibrary = false
    @State private var message: String?

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// 详情加载成功后用完整信息，否则用列表里的简版。
    private var displayed: Manga { detail ?? manga }

    var body: some View {
        List {
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L("source.detail.loading"))
                        .foregroundStyle(.secondary)
                }
            case let .failed(reason):
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("source.failed"), systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(L("source.retry")) {
                        Task { await load() }
                    }
                }
            case .loaded:
                headerSection
                actionSection
                chaptersSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayed.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(L("common.notice"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: 分区

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                CoverThumbnailView(manga: displayed, width: 84, height: 118)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayed.title)
                        .font(.headline)
                    if let author = displayed.author, !author.isEmpty {
                        Text("\(L("source.detail.author"))：\(author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let artist = displayed.artist, !artist.isEmpty {
                        Text("\(L("source.detail.artist"))：\(artist)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if displayed.status != .unknown {
                        Text(statusText(displayed.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if !displayed.genres.isEmpty {
                Text(displayed.genres.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = displayed.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                addToLibrary()
            } label: {
                Label(
                    isInLibrary ? L("source.detail.inLibrary") : L("source.detail.addToLibrary"),
                    systemImage: isInLibrary ? "star.fill" : "star"
                )
            }
            .disabled(isInLibrary)
        } footer: {
            Text(L("source.detail.libraryFooter"))
        }
    }

    private var chaptersSection: some View {
        Section {
            if let chapterError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("source.detail.chaptersFailed"))
                        .font(.footnote)
                    Text(chapterError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(L("source.retry")) {
                        Task { await loadChapters() }
                    }
                }
                .padding(.vertical, 2)
            } else if chapters.isEmpty {
                Text(L("source.detail.noChapters"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chapters) { chapter in
                    NavigationLink {
                        ReaderView(
                            manga: displayed,
                            readingSource: environment.readingSource(for: displayed),
                            startChapterID: chapter.id
                        )
                    } label: {
                        chapterRow(chapter)
                    }
                }
            }
        } header: {
            Text(L("source.detail.chapters"))
        } footer: {
            Text(L("source.detail.chapterFooter"))
        }
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chapter.name)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let number = chapter.chapterNumber, number > 0 {
                    Text("#\(format(number))")
                }
                if let date = chapter.dateUploaded {
                    Text(date.formatted(date: .numeric, time: .omitted))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 行为

    private func load() async {
        phase = .loading
        let key = source.key
        let url = manga.url
        do {
            // 详情只调一次，取不到就整页失败
            let loaded = try await environment.runtimePool.withRunner(for: key) { runner in
                try await runner.mangaDetails(url: url)
            }
            detail = loaded
            phase = .loaded
            isInLibrary = libraryEntryExists(mangaID: loaded.id)
            await loadChapters()
        } catch {
            phase = .failed(SourceBrowseModel.message(for: error))
        }
    }

    private func loadChapters() async {
        chapterError = nil
        let key = source.key
        let url = manga.url
        do {
            chapters = try await environment.runtimePool.withRunner(for: key) { runner in
                try await runner.chapterList(mangaURL: url)
            }
        } catch {
            chapters = []
            chapterError = SourceBrowseModel.message(for: error)
        }
    }

    private func libraryEntryExists(mangaID: String) -> Bool {
        let entry: LibraryEntry? = try? environment.libraryStore.entry(mangaID: mangaID)
        return entry != nil
    }

    private func addToLibrary() {
        guard environment.addToLibrary(displayed) != nil else {
            message = L("source.detail.addFailed")
            return
        }
        isInLibrary = true
        message = L("source.detail.added")
    }

    private func statusText(_ status: MangaStatus) -> String {
        switch status {
        case .unknown: return L("source.status.unknown")
        case .ongoing: return L("source.status.ongoing")
        case .completed: return L("source.status.completed")
        case .licensed: return L("source.status.licensed")
        case .cancelled: return L("source.status.cancelled")
        case .hiatus: return L("source.status.hiatus")
        }
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
