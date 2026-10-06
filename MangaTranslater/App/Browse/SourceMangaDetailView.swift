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
//  下载入口（M3 第二批）：
//  - 单话下载放 `swipeActions`（左滑），不在行内嵌按钮——行本身已经是
//    `NavigationLink`，往里塞按钮会导致「点下载却进了阅读器」这类误触；
//  - 「下载全部」放工具栏，一次入队所有**未下载**的章节（已下载的由协调器跳过）；
//  - 行内只显示状态（已下载 / 下载中 x/y / 失败），点进去才知道进度在哪是更糟的体验。
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
    /// 已下载章节标识（来自协调器的归档快照）。
    @State private var downloadedChapterIDs: Set<String> = []

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
        .toolbar { toolbarContent }
        .task { await load() }
        .task(id: chapterSyncToken) { await refreshDownloadState() }
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
                    .swipeActions(edge: .leading) {
                        chapterDownloadActions(chapter)
                    }
                }
            }
        } header: {
            Text(L("source.detail.chapters"))
        } footer: {
            Text(L("source.detail.downloadFooter"))
        }
    }

    @ViewBuilder
    private func chapterDownloadActions(_ chapter: Chapter) -> some View {
        switch downloadState(for: chapter) {
        case .downloaded:
            Button(role: .destructive) {
                Task {
                    await environment.downloads.deleteArchive(mangaID: displayed.id, chapterID: chapter.id)
                    await refreshDownloadState()
                }
            } label: {
                Label(L("source.detail.removeDownload"), systemImage: "trash")
            }
        case .active, .paused:
            Button(role: .destructive) {
                Task {
                    await environment.downloads.cancel(chapterID: chapter.id)
                    await refreshDownloadState()
                }
            } label: {
                Label(L("downloads.action.cancel"), systemImage: "xmark")
            }
        case .none, .failed, .cancelled:
            Button {
                Task { await download(chapter) }
            } label: {
                Label(L("source.detail.downloadChapter"), systemImage: "arrow.down.circle")
            }
            .tint(.blue)
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
                downloadBadge(for: chapter)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 行内的一小块状态：已下载 / 下载中 x/y / 失败 / 排队中。
    @ViewBuilder
    private func downloadBadge(for chapter: Chapter) -> some View {
        switch downloadState(for: chapter) {
        case .downloaded:
            Label(L("source.detail.downloaded"), systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        case let .active(completed, total):
            Text(String(format: L("downloads.progress"), completed, total))
        case .paused:
            Text(L("downloads.state.paused"))
        case .queued:
            Text(L("source.detail.queued"))
        case .failed:
            Label(L("source.detail.downloadFailed"), systemImage: "exclamationmark.triangle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
        case .none, .cancelled:
            EmptyView()
        }
    }

    // MARK: 下载状态

    /// 章节在下载上的状态（界面用）。
    private enum ChapterDownloadState: Equatable {
        case none
        case queued
        case active(completed: Int, total: Int)
        case paused
        case failed
        case cancelled
        case downloaded
    }

    /// 章节列表或下载队列变化时重新拉状态。
    ///
    /// `downloadedChapterIDs` 在 tasks 里被赋值，所以这里不需要读它的值——
    /// 只用来给 `.task(id:)` 一个「章节变了」的信号。
    private var chapterSyncToken: Int {
        chapters.count + downloadedChapterIDs.count
    }

    private func downloadState(for chapter: Chapter) -> ChapterDownloadState {
        // 归档优先：一个章节既在队列里又被归档是不可能的（协调器会跳过已下载的），
        // 所以先看归档再看队列，顺序不会产生矛盾结果。
        if downloadedChapterIDs.contains(chapter.id) { return .downloaded }
        guard let job = environment.downloads.job(chapterID: chapter.id) else { return .none }
        switch job.state {
        case .pending: return .queued
        case .running: return .active(completed: job.completedPages, total: job.totalPages)
        case .paused: return .paused
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .completed: return .downloaded
        }
    }

    private func refreshDownloadState() async {
        let mangaID = displayed.id
        downloadedChapterIDs = environment.downloads.archivedChapterIDs(mangaID: mangaID)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await downloadAll() }
                } label: {
                    Label(L("source.detail.downloadAll"), systemImage: "arrow.down.circle")
                }
                if !downloadedChapterIDs.isEmpty {
                    Button(role: .destructive) {
                        Task {
                            await environment.downloads.deleteArchives(mangaID: displayed.id)
                            await refreshDownloadState()
                        }
                    } label: {
                        Label(L("source.detail.removeAllDownloads"), systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func download(_ chapter: Chapter) async {
        let result = await environment.downloadChapters([chapter], of: displayed)
        if let message = result.message {
            self.message = message
        }
        await refreshDownloadState()
    }

    private func downloadAll() async {
        let pending = chapters.filter { !downloadedChapterIDs.contains($0.id) }
        guard !pending.isEmpty else {
            message = L("downloads.nothingToDo")
            return
        }
        let result = await environment.downloadChapters(pending, of: displayed)
        message = result.message
        await refreshDownloadState()
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
