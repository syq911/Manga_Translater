//
//  SourceBrowseView.swift
//  MangaTranslater
//
//  某个已安装来源的作品列表：热门 / 搜索 + 翻页。
//
//  设计要点：
//  - 列表状态（翻页、失败保留、末页）全在 `SourceBrowseModel` 里，本视图只画；
//  - **搜索在「提交」时才发请求**：绑定输入框的是 `query`，真正驱动加载的是
//    `submittedQuery`。若把输入框直接接到 `.task(id:)` 上，每敲一个字符都会
//    打一次网络——既是无谓流量，也会让结果列表来回闪；
//  - 切换模式 / 提交新查询时**重建模型**（加载器与查询串绑定），
//    避免出现「显示的是上一次查询结果」这类状态错位；
//  - 只有末行出现时才请求下一页（比滚动到底部事件简单且够用）。
//

import SwiftUI
import AppCore
import SourceEngine

struct SourceBrowseView: View {

    let source: InstalledSource

    @Environment(AppEnvironment.self) private var environment

    @State private var mode: Mode = .popular
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var model: SourceBrowseModel?

    enum Mode: String, CaseIterable {
        case popular
        case latest
        case search

        var title: String {
            switch self {
            case .popular: return L("source.mode.popular")
            case .latest: return L("source.mode.latest")
            case .search: return L("source.mode.search")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if mode == .search {
                searchField
            }

            list
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskKey) { await startLoading() }
    }

    /// 驱动加载的键：模式 + **已提交**的查询串。
    private var taskKey: String {
        "\(mode.rawValue)|\(submittedQuery)"
    }

    // MARK: 子视图

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("source.search.placeholder"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { submittedQuery = query }
            if !query.isEmpty {
                Button {
                    query = ""
                    submittedQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var list: some View {
        if let model {
            List {
                switch model.phase {
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(L("source.loading"))
                            .foregroundStyle(.secondary)
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("source.failed"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(L("source.retry")) {
                            Task { await model.refresh() }
                        }
                    }
                    .padding(.vertical, 4)
                case .loaded:
                    if model.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.items) { manga in
                            NavigationLink {
                                SourceMangaDetailView(manga: manga, source: source)
                            } label: {
                                SourceMangaRow(manga: manga)
                            }
                            .onAppear {
                                // 末行出现即预取下一页
                                if manga.id == model.items.last?.id {
                                    Task { await model.loadNextPage() }
                                }
                            }
                        }
                        if model.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyMessage: String {
        mode == .search ? L("source.search.empty") : L("source.empty")
    }

    // MARK: 行为

    private func startLoading() async {
        let model = makeModel()
        self.model = model
        await model.loadFirstPage()
    }

    private func makeModel() -> SourceBrowseModel {
        let key = source.key
        // 只捕获 Sendable 的东西（actor + 值类型）：`AppEnvironment` 是
        // `@MainActor` 隔离的，把它整个捕进 `@Sendable` 加载器会引来隔离告警。
        let pool = environment.runtimePool

        switch mode {
        case .popular:
            return SourceBrowseModel { page in
                try await pool.withRunner(for: key) { runner in
                    try await runner.popularManga(page: page)
                }
            }
        case .latest:
            // 契约里 `getLatestUpdates` 是可选方法；源没实现时宿主回退到热门，
            // 因此这里不需要额外的分支（回退发生在 SourceRunner 里）。
            return SourceBrowseModel { page in
                try await pool.withRunner(for: key) { runner in
                    try await runner.latestUpdates(page: page)
                }
            }
        case .search:
            let text = submittedQuery
            return SourceBrowseModel { page in
                try await pool.withRunner(for: key) { runner in
                    try await runner.search(page: page, query: text)
                }
            }
        }
    }
}

// MARK: - 行

/// 作品行：封面 + 标题 + 作者 + 是否已在书架。热门与搜索列表共用。
struct SourceMangaRow: View {

    @Environment(AppEnvironment.self) private var environment
    let manga: Manga

    var body: some View {
        HStack(spacing: 10) {
            CoverThumbnailView(manga: manga)
            VStack(alignment: .leading, spacing: 2) {
                Text(manga.title)
                    .lineLimit(2)
                if let author = manga.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isInLibrary {
                    Label(L("source.inLibrary"), systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isInLibrary: Bool {
        // `entry(mangaID:)` 返回 Optional 且会抛错；`try?` 的结果已被 Swift 折叠
        // 成单层 Optional（SE-0230），所以这里只需判 nil。
        let entry: LibraryEntry? = try? environment.libraryStore.entry(mangaID: manga.id)
        return entry != nil
    }
}
