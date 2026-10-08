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
    /// 排序偏好**持久化**：用 `@State` 的话切走再回来、或重启就回到默认，
    /// 用户会以为排序坏了（解析规则见 `LibraryPreferences`）。
    @AppStorage(LibraryPreferences.sortOrderKey)
    private var sortOrderRaw = LibraryPreferences.defaultSortOrder.rawValue
    /// 布局偏好（手册 §8.1 的收藏网格 / 可左滑的列表）。同样持久化。
    @AppStorage(LibraryPreferences.displayModeKey)
    private var displayModeRaw = LibraryPreferences.defaultDisplayMode.rawValue
    @State private var showsImporter = false
    @State private var message: String?
    /// 待确认的「移出书架」。
    @State private var pendingRemoval: LibraryEntry?

    private var sortOrder: LibrarySortOrder {
        LibraryPreferences.sortOrder(from: sortOrderRaw)
    }

    private var displayMode: LibraryPreferences.DisplayMode {
        LibraryPreferences.displayMode(from: displayModeRaw)
    }

    private var displayModeBinding: Binding<LibraryPreferences.DisplayMode> {
        Binding(
            get: { LibraryPreferences.displayMode(from: displayModeRaw) },
            set: { displayModeRaw = $0.rawValue }
        )
    }

    /// 最近阅读条的内容（手册 §8.1）：按 `lastReadAt` 倒序取前几部。
    ///
    /// 直接用书架条目里的 `lastReadAt`，不额外查历史表：
    /// 「最近在读的那几本」正是用户最常回来的入口。
    private var recentEntries: [LibraryEntry] {
        entries
            .filter { $0.lastReadAt != nil }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    /// 网格列：自适应宽度，窄屏两列、iPad 四列以上。
    private static let gridColumns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    private var sortOrderBinding: Binding<LibrarySortOrder> {
        Binding(
            get: { LibraryPreferences.sortOrder(from: sortOrderRaw) },
            set: { newValue in
                sortOrderRaw = newValue.rawValue
                reload()
            }
        )
    }

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
            .alert(L("common.notice"), isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button(L("common.ok"), role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog(
                L("library.confirm.remove.title"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("library.menu.remove"), role: .destructive) {
                    if let entry = pendingRemoval { performRemoval(entry) }
                    pendingRemoval = nil
                }
                Button(L("common.cancel"), role: .cancel) { pendingRemoval = nil }
            } message: {
                // 这句是必须的：移出书架会**一并丢掉阅读进度与分类归属**，
                // 用户以为只是「收藏没了」的话，下次进来会发现自己从头开始。
                Text(String(
                    format: L("library.confirm.remove.message"),
                    pendingRemoval?.manga.title ?? ""
                ))
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
            Button(L("library.importFiles")) { showsImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var entryList: some View {
        List {
            if !environment.isLibraryPersistent {
                Section {
                    Label(L("library.notPersistent"), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }

            if !recentEntries.isEmpty {
                recentSection
            }

            // 手册 §8.1 的「收藏网格」，同时保留列表：
            // 网格是封面优先的浏览方式；列表是**唯一能用左滑手势**的布局。
            // 两种都留着，选择持久化（`LibraryPreferences.DisplayMode`）。
            switch displayMode {
            case .grid:
                gridSection
            case .list:
                listSection
            }
        }
        .listStyle(.insetGrouped)
        // 手册 §5.3：下拉逐源拉章节列表比对
        .refreshable { await checkForUpdates() }
    }

    /// 最近阅读条。
    private var recentSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(recentEntries) { entry in
                        NavigationLink {
                            ReaderView(
                                manga: entry.manga,
                                readingSource: environment.readingSource(for: entry.manga)
                            )
                        } label: {
                            recentCell(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L("library.recent.title"))
        }
    }

    private func recentCell(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverThumbnailView(manga: entry.manga, width: 68, height: 96)
            Text(entry.manga.title)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 68, alignment: .leading)
        }
    }

    private var listSection: some View {
        Section {
            ForEach(entries) { entry in
                NavigationLink {
                    readerDestination(entry)
                } label: {
                    row(for: entry)
                }
                .contextMenu { rowMenu(for: entry) }
                // 刻意不用 `.onDelete`：它会**立刻**删掉，而「移出书架」按策略
                // 必须先确认（`DestructiveActionPolicy.requiresConfirmation(.removeFromLibrary)`）。
                // 换成 swipeActions 之后，手势与长按菜单走的是同一条确认路径。
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        requestRemoval(entry)
                    } label: {
                        Label(L("library.menu.remove"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var gridSection: some View {
        Section {
            LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                ForEach(entries) { entry in
                    NavigationLink {
                        readerDestination(entry)
                    } label: {
                        gridCell(entry)
                    }
                    .buttonStyle(.plain)
                    // 网格里没有左滑（那是 `List` 的能力），管理动作统一走长按菜单
                    .contextMenu { rowMenu(for: entry) }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(String(format: L("library.grid.count"), entries.count))
        }
    }

    @ViewBuilder
    private func readerDestination(_ entry: LibraryEntry) -> some View {
        ReaderView(
            manga: entry.manga,
            readingSource: environment.readingSource(for: entry.manga)
        )
    }

    private func gridCell(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                CoverThumbnailView(manga: entry.manga, width: 92, height: 130)
                if entry.unreadCount > 0 {
                    unreadBadge(entry.unreadCount)
                }
            }
            HStack(spacing: 4) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(entry.manga.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Text(progressText(for: entry))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 未读角标（手册 §8.1 明确要求）。数字是「新章节数」。
    private func unreadBadge(_ count: Int) -> some View {
        Text(String(format: L("library.unreadBadge"), count))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red, in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
    }

    /// 长按菜单：分类归属与置顶（相比滑动删除，这些操作更适合放在菜单里）。
    @ViewBuilder
    private func rowMenu(for entry: LibraryEntry) -> some View {
        Menu {
            Button {
                move(entry, to: nil)
            } label: {
                Label(L("library.menu.removeFromCategory"), systemImage: entry.categoryID == nil ? "checkmark" : "folder.badge.minus")
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
            Label(L("library.menu.moveToCategory"), systemImage: "folder")
        }

        Button {
            togglePin(entry)
        } label: {
            Label(entry.isPinned ? L("library.menu.unpin") : L("library.menu.pin"), systemImage: entry.isPinned ? "pin.slash" : "pin")
        }

        Button(role: .destructive) {
            requestRemoval(entry)
        } label: {
            Label(L("library.menu.remove"), systemImage: "trash")
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
                    if entry.unreadCount > 0 {
                        unreadBadge(entry.unreadCount)
                    }
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
                // 菜单的**形状**（有哪些项、顺序、哪一项被选中）来自可单测的
                // `LibraryFilterMenu`；这里只把中性枚举映射成文案与图标。
                ForEach(LibraryFilterMenu.targets(categories: categories)) { target in
                    switch target {
                    case .all:
                        Button {
                            selectCategory(nil)
                        } label: {
                            Label(
                                L("library.filter.all"),
                                systemImage: selectedCategoryID == nil ? "checkmark" : "books.vertical"
                            )
                        }
                        if !categories.isEmpty { Divider() }
                    case let .category(id, name):
                        Button {
                            selectCategory(id)
                        } label: {
                            Label(name, systemImage: selectedCategoryID == id ? "checkmark" : "folder")
                        }
                    }
                }
                Divider()
                NavigationLink {
                    CategoryManagerView()
                } label: {
                    Label(L("library.filter.manageCategories"), systemImage: "folder.badge.gearshape")
                }
            } label: {
                Label(categoryFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker(L("library.sort.label"), selection: sortOrderBinding) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Text(order.localizedName).tag(order)
                    }
                }
                Picker(L("library.display.label"), selection: displayModeBinding) {
                    Text(L("library.display.grid")).tag(LibraryPreferences.DisplayMode.grid)
                    Text(L("library.display.list")).tag(LibraryPreferences.DisplayMode.list)
                }
            } label: {
                Label(L("library.sort.label"), systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showsImporter = true
            } label: {
                Label(L("library.action.import"), systemImage: "plus")
            }
        }
    }

    private var categoryFilterLabel: String {
        guard let selectedCategoryID else { return L("library.filter.all") }
        return categories.first { $0.id == selectedCategoryID }?.name ?? L("library.filter.all")
    }

    // MARK: 行为

    private func progressText(for entry: LibraryEntry) -> String {
        guard entry.lastReadChapterID != nil else { return L("library.progress.notStarted") }
        let page = (entry.lastReadPageIndex ?? 0) + 1
        if let readAt = entry.lastReadAt {
            return String(
                format: L("library.progress.pageWithDate"),
                page,
                Self.relativeFormatter.localizedString(for: readAt, relativeTo: Date())
            )
        }
        return String(format: L("library.progress.page"), page)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func reload() {
        categories = (try? environment.libraryStore.categories()) ?? []
        // 分类可能已在分类管理页被删掉，此时回退到「全部作品」，
        // 否则会停在一个空列表上让用户以为书架坏了（判定在 `LibraryFilterMenu`，可单测）。
        selectedCategoryID = LibraryFilterMenu.validSelection(selectedCategoryID, categories: categories)
        entries = (try? environment.libraryStore.entries(sortedBy: sortOrder, categoryID: selectedCategoryID)) ?? []
    }

    private func selectCategory(_ id: String?) {
        selectedCategoryID = id
        reload()
    }

    // MARK: 检查更新

    /// 下拉刷新：先重读本地库，再逐源比对章节列表。
    ///
    /// 检查的是**全部**条目（不受当前分类筛选影响）——「检查更新」问的是
    /// 「我收藏的东西有没有新的」，而不是「我此刻看着的这一页有没有新的」。
    private func checkForUpdates() async {
        reload()
        let all = (try? environment.libraryStore.entries(sortedBy: .recentlyAdded, categoryID: nil)) ?? []
        let outcome = await environment.makeLibraryUpdateChecker().check(all)
        reload()
        message = Self.updateMessage(outcome)
    }

    /// 把检查结果压成一句话。
    ///
    /// 刻意把「判断不出来」和「拉取失败」分开报：
    /// 前者是源没给足够信息（不是错误），后者是网络/解析出问题（要去查）。
    /// 混在一起说「部分失败」会让用户以为哪里坏了。
    static func updateMessage(_ outcome: LibraryUpdateOutcome) -> String {
        if outcome.checked == 0 {
            return L("library.refresh.nothingToCheck")
        }
        if outcome.withNewChapters == 0, outcome.failed == 0 {
            return String(format: L("library.refresh.allUpToDate"), outcome.checked)
        }
        return String(
            format: L("library.refresh.done"),
            outcome.checked,
            outcome.withNewChapters,
            outcome.newChapterTotal,
            outcome.failed
        )
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

    /// 请求移出书架：按策略决定「先确认」还是「直接移」。
    ///
    /// 用策略层裁决（而不是在这里写死一个 `true`）是为了让「要不要确认」
    /// 只有一个出口：策略改了，所有入口一起改。
    private func requestRemoval(_ entry: LibraryEntry) {
        if DestructiveActionPolicy.requiresConfirmation(.removeFromLibrary) {
            pendingRemoval = entry
        } else {
            performRemoval(entry)
        }
    }

    /// 真正移出书架。
    ///
    /// **不会**删除已下载的文件（那是下载页的职责），但条目本身带着阅读进度
    /// 与分类归属，所以这一步是「半可逆」的——确认文案里必须说清。
    private func performRemoval(_ entry: LibraryEntry) {
        _ = try? environment.libraryStore.remove(mangaID: entry.manga.id)
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
                    failures.append(String(format: L("library.import.failureLine"), url.lastPathComponent, reason))
                }
            }

            reload()
            message = failures.isEmpty
                ? String(format: L("library.import.done"), succeeded)
                : String(
                    format: L("library.import.partial"),
                    succeeded,
                    failures.count,
                    failures.joined(separator: "\n")
                )

        case let .failure(error):
            message = String(format: L("library.import.pickFailed"), error.localizedDescription)
        }
    }
}

#Preview {
    LibraryView()
        .environment(AppEnvironment.makeDefault())
}
