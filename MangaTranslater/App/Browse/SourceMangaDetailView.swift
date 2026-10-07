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

    @Environment(AppEnvironment.self) private var environment

    @State private var phase: Phase = .loading
    @State private var detail: Manga?
    @State private var chapters: [Chapter] = []
    @State private var chapterError: String?
    @State private var isInLibrary = false
    @State private var message: String?
    /// 已下载章节标识（来自协调器的归档快照）。
    @State private var downloadedChapterIDs: Set<String> = []
    /// 待二次确认的破坏性操作。
    ///
    /// 「要不要确认」不在这里判断——由 `DestructiveActionPolicy` 说了算，
    /// 这样作品详情页与下载页对同一件事（删一个归档）**必然是同一个行为**。
    @State private var confirmation: Confirmation?

    /// 作用在本页的破坏性操作。
    private enum Confirmation: Identifiable {
        case deleteChapter(chapterID: String, name: String)
        case deleteAllArchives

        var id: String {
            switch self {
            case let .deleteChapter(chapterID, _): return "delete-\(chapterID)"
            case .deleteAllArchives: return "deleteAll"
            }
        }
    }

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
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            confirmationButtons
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: 二次确认

    private var confirmationTitle: String {
        switch confirmation {
        case .deleteChapter, .deleteAllArchives:
            return L("downloads.confirm.delete.title")
        case nil:
            return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case let .deleteChapter(_, name):
            return String(format: L("downloads.confirm.delete.message"), name)
        case .deleteAllArchives:
            return String(format: L("downloads.confirm.delete.message"), displayed.title)
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch confirmation {
        case let .deleteChapter(chapterID, _):
            Button(L("downloads.action.delete"), role: .destructive) {
                confirmation = nil
                Task { await deleteArchive(chapterID: chapterID) }
            }
        case .deleteAllArchives:
            Button(L("downloads.action.deleteAll"), role: .destructive) {
                confirmation = nil
                Task {
                    await environment.downloads.deleteArchives(mangaID: displayed.id)
                    await refreshDownloadState()
                }
            }
        case nil:
            EmptyView()
        }
        Button(L("common.cancel"), role: .cancel) { confirmation = nil }
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
                        Text(String(format: L("source.detail.field"), L("source.detail.author"), author))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let artist = displayed.artist, !artist.isEmpty {
                        Text(String(format: L("source.detail.field"), L("source.detail.artist"), artist))
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

    /// 章节行左滑出现的那个按钮。
    ///
    /// 「什么状态出什么按钮」的映射住在 `ChapterActionMenu`（可单测穷举），
    /// 这里只负责把动作接到协调器上。这样作品详情页与下载页对同一状态
    /// **不会出现两种行为**——两处共用同一份映射。
    @ViewBuilder
    private func chapterDownloadActions(_ chapter: Chapter) -> some View {
        switch ChapterActionMenu.action(for: downloadState(for: chapter)) {
        case .deleteArchive:
            // 删归档要二次确认（与下载页一致）；策略由 `DestructiveActionPolicy` 裁决
            Button(role: .destructive) {
                requestDeleteArchive(chapter)
            } label: {
                Label(L("source.detail.removeDownload"), systemImage: "trash")
            }
        case .cancel:
            Button(role: .destructive) {
                Task {
                    await environment.downloads.cancel(chapterID: chapter.id)
                    await refreshDownloadState()
                }
            } label: {
                Label(L("downloads.action.cancel"), systemImage: "xmark")
            }
        case .download:
            // `.queued`（已排队但还没跑）也走这里，否则用户点了下载收不回来
            Button {
                Task { await download(chapter) }
            } label: {
                Label(L("source.detail.downloadChapter"), systemImage: "arrow.down.circle")
            }
            .tint(.blue)
        }
    }

    /// 请求删除某章的归档：按策略决定「先确认」还是「直接删」。
    private func requestDeleteArchive(_ chapter: Chapter) {
        if DestructiveActionPolicy.requiresConfirmation(.deleteChapterArchive) {
            confirmation = .deleteChapter(chapterID: chapter.id, name: chapter.name)
        } else {
            Task { await deleteArchive(chapterID: chapter.id) }
        }
    }

    private func deleteArchive(chapterID: String) async {
        await environment.downloads.deleteArchive(mangaID: displayed.id, chapterID: chapterID)
        await refreshDownloadState()
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

    /// 章节在下载上的状态。
    ///
    /// 类型本身住在 `AppCore.ChapterDownloadState`——它同时也是「左滑该出哪个按钮」
    /// （`ChapterActionMenu`）的输入，因此必须能被单测穷举，而不能是视图里的私有枚举。
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

    /// 章节列表或下载队列变化时重新拉状态。
    ///
    /// `downloadedChapterIDs` 在 tasks 里被赋值，所以这里不需要读它的值——
    /// 只用来给 `.task(id:)` 一个「章节变了」的信号。
    private var chapterSyncToken: Int {
        chapters.count + downloadedChapterIDs.count
    }

    private func refreshDownloadState() async {
        let mangaID = displayed.id
        // 先刷新归档快照再读：`archivedChapterIDs` 读的是快照（不碰磁盘），
        // 于是每次渲染都查一次也不会产生 IO。
        await environment.downloads.refreshArchives()
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
                        // 删掉某作品的全部下载同样要确认（与下载页一致）
                        if DestructiveActionPolicy.requiresConfirmation(.deleteMangaArchives) {
                            confirmation = .deleteAllArchives
                        } else {
                            Task {
                                await environment.downloads.deleteArchives(mangaID: displayed.id)
                                await refreshDownloadState()
                            }
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
        let sourceID = manga.sourceID
        let url = manga.url
        do {
            // 详情只调一次，取不到就整页失败
            let loaded = try await environment.dataSource(for: sourceID).mangaDetails(url: url)
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
        let sourceID = manga.sourceID
        let url = manga.url
        let identifier = displayed.id
        do {
            chapters = try await environment.dataSource(for: sourceID)
                .chapterList(mangaURL: url, mangaID: identifier)
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
