//
//  DownloadsView.swift
//  MangaTranslater
//
//  下载页：进行中的队列 + 已下载（按作品分组，可离线阅读 / 导出 / 删除）。
//
//  视图只画状态：所有编排（入队、进度、归档、删除）都在 `DownloadCoordinator`，
//  因此这里全是「读快照 → 画出来 → 把按钮接到协调器」。
//
//  一个刻意的选择：**已下载的章节点进去直接阅读**。归档是本地 CBZ，
//  阅读器读它与读用户自己导入的漫画是同一条路径（`RemoteReadingSource`
//  先查归档），所以「下完能看」这件事不需要额外接线。
//

import SwiftUI
import AppCore
import ComicDownload

struct DownloadsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var confirmation: Confirmation?

    /// 需要二次确认的破坏性操作。
    private enum Confirmation: Identifiable {
        case cancelAll(count: Int)
        case deleteChapter(mangaID: String, chapterID: String, name: String)
        case deleteManga(mangaID: String, title: String)
        case deleteAll(count: Int)

        var id: String {
            switch self {
            case let .cancelAll(count): return "cancelAll-\(count)"
            case let .deleteChapter(_, chapterID, _): return "delete-\(chapterID)"
            case let .deleteManga(mangaID, _): return "deleteManga-\(mangaID)"
            case let .deleteAll(count): return "deleteAll-\(count)"
            }
        }
    }

    private var downloads: DownloadCoordinator { environment.downloads }

    private var activeJobs: [DownloadJob] {
        downloads.jobs.filter { !$0.state.isTerminal }
    }

    private var finishedJobs: [DownloadJob] {
        downloads.jobs.filter { $0.state.isTerminal }
    }

    var body: some View {
        NavigationStack {
            List {
                if activeJobs.isEmpty, downloads.archivedGroups.isEmpty, finishedJobs.isEmpty {
                    emptyState
                }

                if !activeJobs.isEmpty {
                    activeSection
                }

                archivedSections

                if !finishedJobs.isEmpty {
                    finishedSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("tab.downloads"))
            .toolbar { toolbarContent }
            .task { await downloads.refresh() }
            .refreshable { await downloads.refresh() }
            .alert(L("common.notice"), isPresented: Binding(
                get: { downloads.message != nil },
                set: { if !$0 { downloads.message = nil } }
            )) {
                Button(L("common.ok"), role: .cancel) { downloads.message = nil }
            } message: {
                Text(downloads.message ?? "")
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
    }

    // MARK: 空状态

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L("downloads.empty.title"), systemImage: "arrow.down.circle")
        } description: {
            Text(L("downloads.empty.body"))
        }
    }

    // MARK: 进行中

    private var activeSection: some View {
        Section {
            ForEach(activeJobs) { job in
                DownloadJobRow(job: job) { action in
                    Task { await perform(action, on: job) }
                }
            }
        } header: {
            Text(L("downloads.section.active"))
        } footer: {
            Text(L("downloads.active.footer"))
        }
    }

    // MARK: 已下载

    @ViewBuilder
    private var archivedSections: some View {
        ForEach(downloads.archivedGroups) { group in
            Section {
                ForEach(group.chapters) { record in
                    archivedRow(record)
                }
            } header: {
                HStack {
                    Text(title(forMangaID: group.mangaID, fallback: group.chapters.first?.mangaTitle))
                    Spacer()
                    Text(String(format: L("downloads.group.meta"), group.chapters.count, bytes(group.totalBytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L("downloads.group.footer"))
            }
        }
    }

    @ViewBuilder
    private func archivedRow(_ record: DownloadedChapter) -> some View {
        Group {
            if let target = readerTarget(for: record) {
                NavigationLink {
                    ReaderView(
                        manga: target,
                        readingSource: environment.readingSource(for: target),
                        startChapterID: record.chapterID
                    )
                } label: {
                    archivedLabel(record)
                }
            } else {
                archivedLabel(record)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                confirmation = .deleteChapter(
                    mangaID: record.mangaID,
                    chapterID: record.chapterID,
                    name: record.chapterName
                )
            } label: {
                Label(L("downloads.action.delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if let url = downloads.archiveURL(mangaID: record.mangaID, chapterID: record.chapterID) {
                ShareLink(item: url) {
                    Label(L("downloads.action.export"), systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
        }
    }

    private func archivedLabel(_ record: DownloadedChapter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.chapterName)
                .lineLimit(2)
            Text(String(format: L("downloads.chapter.meta"), record.pageCount, bytes(record.byteCount)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 已结束（失败 / 取消）

    private var finishedSection: some View {
        Section {
            ForEach(finishedJobs) { job in
                DownloadJobRow(job: job) { action in
                    Task { await perform(action, on: job) }
                }
            }
        } header: {
            Text(L("downloads.section.finished"))
        } footer: {
            Text(L("downloads.finished.footer"))
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !activeJobs.isEmpty {
                    Button(role: .destructive) {
                        confirmation = .cancelAll(count: activeJobs.count)
                    } label: {
                        Label(L("downloads.action.cancelAll"), systemImage: "xmark.circle")
                    }
                }
                ForEach(downloads.archivedGroups) { group in
                    Button(role: .destructive) {
                        confirmation = .deleteManga(
                            mangaID: group.mangaID,
                            title: title(forMangaID: group.mangaID, fallback: group.chapters.first?.mangaTitle)
                        )
                    } label: {
                        Label(
                            String(
                                format: L("downloads.action.deleteManga"),
                                title(forMangaID: group.mangaID, fallback: group.chapters.first?.mangaTitle)
                            ),
                            systemImage: "trash"
                        )
                    }
                }
                if downloads.archivedChapterCount > 0 {
                    Button(role: .destructive) {
                        confirmation = .deleteAll(count: downloads.archivedChapterCount)
                    } label: {
                        Label(L("downloads.action.deleteAll"), systemImage: "trash.slash")
                    }
                }
                if !finishedJobs.isEmpty {
                    Button {
                        Task { await downloads.removeFinished() }
                    } label: {
                        Label(L("downloads.action.clearFinished"), systemImage: "eraser")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: 确认对话框

    private var confirmationTitle: String {
        switch confirmation {
        case .cancelAll: return L("downloads.confirm.cancelAll.title")
        case .deleteChapter: return L("downloads.confirm.delete.title")
        case .deleteManga: return L("downloads.confirm.delete.title")
        case .deleteAll: return L("downloads.confirm.deleteAll.title")
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case let .cancelAll(count):
            return String(format: L("downloads.confirm.cancelAll.message"), count)
        case let .deleteChapter(_, _, name):
            return String(format: L("downloads.confirm.delete.message"), name)
        case let .deleteManga(_, title):
            return String(format: L("downloads.confirm.delete.message"), title)
        case let .deleteAll(count):
            return String(format: L("downloads.confirm.deleteAll.message"), count)
        case nil: return ""
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch confirmation {
        case .cancelAll:
            Button(L("downloads.action.cancelAll"), role: .destructive) {
                confirmation = nil
                Task { await downloads.cancelAll() }
            }
        case let .deleteChapter(mangaID, chapterID, _):
            Button(L("downloads.action.delete"), role: .destructive) {
                confirmation = nil
                Task { await downloads.deleteArchive(mangaID: mangaID, chapterID: chapterID) }
            }
        case let .deleteManga(mangaID, _):
            Button(L("downloads.action.delete"), role: .destructive) {
                confirmation = nil
                Task { await downloads.deleteArchives(mangaID: mangaID) }
            }
        case .deleteAll:
            Button(L("downloads.action.deleteAll"), role: .destructive) {
                confirmation = nil
                Task { await downloads.deleteAllArchives() }
            }
        case nil:
            EmptyView()
        }
        Button(L("common.cancel"), role: .cancel) { confirmation = nil }
    }

    // MARK: 行为

    private func perform(_ action: DownloadJobRow.Action, on job: DownloadJob) async {
        switch action {
        case .pause: await downloads.pause(chapterID: job.chapterID)
        case .resume: await downloads.resume(chapterID: job.chapterID)
        case .cancel: await downloads.cancel(chapterID: job.chapterID)
        case .retry: await downloads.retry(chapterID: job.chapterID)
        }
    }

    /// 已下载章节的阅读目标：作品在书架里才给入口。
    ///
    /// 不在书架里就没有作品信息可用（归档清单里只有主键），
    /// 此时不装出「能点」的样子——给一个点了没反应的导航链接更糟。
    /// 返回类型写成 `Manga?` 而不是带标签的单元素元组：
    /// `(manga: Manga)?` 在 `return` 处会报
    /// 「cannot create a single-element tuple with an element label」。
    private func readerTarget(for record: DownloadedChapter) -> Manga? {
        environment.libraryEntryManga(mangaID: record.mangaID)
    }

    private func title(forMangaID mangaID: String, fallback: String?) -> String {
        if let title = environment.libraryEntryManga(mangaID: mangaID)?.title, !title.isEmpty {
            return title
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        return L("downloads.unknownManga")
    }

    private func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }
}

// MARK: - 任务行

/// 一个下载任务（进行中或已结束）。
///
/// 控制按钮放在 `swipeActions` 里，行本身保持清爽；
/// 行内只显示状态与进度——「一眼看出卡在哪」比「所有按钮都露出来」重要。
private struct DownloadJobRow: View {

    enum Action {
        case pause
        case resume
        case cancel
        case retry
    }

    let job: DownloadJob
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(job.chapterName)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(stateText)
                    .font(.caption2)
                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
            }

            if !job.mangaTitle.isEmpty {
                Text(job.mangaTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if job.state == .running || job.state == .pending || job.state == .paused {
                ProgressView(value: job.progress)
                Text(String(format: L("downloads.progress"), job.completedPages, job.totalPages))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let reason = job.errorMessage, !reason.isEmpty {
                Text(String(format: L("downloads.failed.reason"), reason))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            switch job.state {
            case .running, .pending:
                Button {
                    onAction(.pause)
                } label: {
                    Label(L("downloads.action.pause"), systemImage: "pause")
                }
                .tint(.orange)
            case .paused:
                Button {
                    onAction(.resume)
                } label: {
                    Label(L("downloads.action.resume"), systemImage: "play")
                }
                .tint(.green)
            case .failed, .cancelled:
                Button {
                    onAction(.retry)
                } label: {
                    Label(L("downloads.action.retry"), systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            case .completed:
                EmptyView()
            }
        }
        .swipeActions(edge: .leading) {
            if !job.state.isTerminal {
                Button(role: .destructive) {
                    onAction(.cancel)
                } label: {
                    Label(L("downloads.action.cancel"), systemImage: "xmark")
                }
            }
        }
    }

    private var stateText: String {
        switch job.state {
        case .pending: return L("downloads.state.pending")
        case .running: return L("downloads.state.running")
        case .paused: return L("downloads.state.paused")
        case .completed: return L("downloads.state.completed")
        case .failed: return L("downloads.state.failed")
        case .cancelled: return L("downloads.state.cancelled")
        }
    }
}

#Preview {
    DownloadsView()
        .environment(AppEnvironment.makeDefault())
}
