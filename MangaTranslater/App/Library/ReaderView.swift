//
//  ReaderView.swift
//  MangaTranslater
//
//  阅读器（本地文件源与在线来源共用）。
//
//  职责划分：
//  - 翻页/翻章/预加载范围的**规则**在 `AppCore.ReaderSession`（可单元测试）；
//  - 缩放/平移的**规则**在 `AppCore.ZoomState`（可单元测试）；
//  - 「数据从哪来」在 `MangaReadingSource`（本地 / 在线各自实现，见
//    `SourceEngine.ReadingSources`）；
//  - 本视图只做三件事：把当前页画出来、把手势转成「前进/后退/缩放」、把进度写回书架。
//
//  因此这里**没有**任何「本地还是在线」的分支：本地解压与在线下载
//  对阅读器都是「取第 N 页的数据」。
//
//  两个容易踩的点：
//  1. 预加载是并发的（`withTaskGroup`），换页/换章时要**取消上一次预加载**，
//     否则快速翻页会把多批下载叠起来；
//  2. 只有作品在书架里才写进度——`updateProgress` 对不在书架的作品会抛
//     `entryNotFound`，翻一页记一条失败日志毫无意义。阅读器顶部提供星标，
//     一键加入书架后进度才会被记录。
//

import SwiftUI
import UIKit
import Translation
import AppCore
import SourceEngine

struct ReaderView: View {

    let manga: Manga
    /// 阅读数据来源（本地文件源 / 在线来源）。
    let readingSource: MangaReadingSource
    /// 进入时定位到的章节（在线来源从章节列表点进来时用）。
    var startChapterID: String?

    @Environment(AppEnvironment.self) private var environment
    /// 打开外部网页（「升级云服务」用）。App 内不出现收银台，付款只在官网完成。
    @Environment(\.openURL) private var openURL

    @State private var session: ReaderSession?
    @State private var pages: [ComicPage] = []
    @State private var pageImages: [Int: Data] = [:]
    @State private var message: String?
    @State private var isLoading = true
    /// 是否已在书架（决定要不要写进度）。
    @State private var isInLibrary = false
    /// 正在进行的预加载任务（换页前先取消，避免多批下载叠加）。
    @State private var preloadTask: Task<Void, Never>?
    /// 页内翻译编排器（进入阅读器时创建，退出时重置）。
    @State private var translation: TranslationController?
    /// 顶栏 / 底栏是否可见。
    ///
    /// 手册 §8.2 的交互是「三区点按：左右翻页、**点中央呼出**顶栏」——
    /// 也就是沉浸阅读时顶栏应当能收起来，而不是永久占掉一块阅读面积。
    @State private var showsChrome = true
    @State private var showsReaderSettings = false
    @State private var showsJumpSheet = false

    /// 缩放 / 平移状态。
    @State private var zoom = ZoomState()
    /// 捏合手势开始时的刻度（手势过程中作为基准）。
    @State private var pinchBaseScale: CGFloat?
    /// 拖动手势开始时的位移（用于放大后平移）。
    @State private var dragStartOffset: CGSize?
    /// 阅读区域尺寸（用于钳制平移）。
    @State private var containerSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                readerBackground
                content
            }
            .contentShape(Rectangle())
            // 双击缩放；单击中央收起 / 呼出顶栏与底栏。
            // 两个手势都挂在同一层：SwiftUI 会把「单击」推迟到双击判定窗口之后，
            // 因此双击缩放不会顺带把工具栏收起来。
            .onTapGesture(count: 2) { toggleDoubleTap() }
            .onTapGesture { toggleChrome() }
            .overlay(alignment: .leading) { tapZone(isLeading: true) }
            .overlay(alignment: .trailing) { tapZone(isLeading: false) }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)

            if showsChrome {
                bottomBar
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .overlay(alignment: .top) { notices }
        // Apple 端上翻译：框架要求由 SwiftUI 提供 TranslationSession，
        // 桥负责把「待翻译文本 + continuation」和这次会话对上。
        .translationTask(translation?.appleBridge.configuration) { session in
            // 显式绑定成局部常量再调用：`translation?.method()` 的表达式类型是 `Void?`，
            // 在「期望 Void」的闭包里依赖单表达式丢弃规则虽然能过，
            // 但写成两句更明确，也不会因为编译器的边缘行为变化而出问题。
            guard let controller = translation else { return }
            await controller.appleBridge.run(session: session)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // 收起时连导航栏一起收（返回按钮也在里面），点中央再呼出——
        // 手册 §8.2 的「点中央呼出」就是这个意思。
        .toolbar(showsChrome ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    addToLibrary()
                } label: {
                    Image(systemName: isInLibrary ? "star.fill" : "star")
                }
                .disabled(isInLibrary)
                .accessibilityLabel(L("source.detail.addToLibrary"))

                // ⤓ 下载本话（手册 §8.2 的顶栏线框图）
                Button {
                    toggleDownload()
                } label: {
                    Image(systemName: downloadIconName)
                }
                .disabled(manga.sourceID == .local || session == nil)
                .accessibilityLabel(L("reader.downloadChapter"))

                // Ⓣ 翻译
                Button {
                    toggleTranslation()
                } label: {
                    Image(systemName: translation?.showsTranslation == true
                          ? "character.book.closed.fill"
                          : "character.book.closed")
                }
                .disabled(translation == nil || isLoading)
                .accessibilityLabel(L("translation.reader.toggle"))

                // 目录：跳章 / 跳页
                Button {
                    showsJumpSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .disabled(session == nil)
                .accessibilityLabel(L("reader.jump.title"))

                // ⚙ 阅读设置
                Button {
                    showsReaderSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L("settings.section.reader"))
            }
        }
        .task { await bootstrap() }
        .onAppear { applyIdleTimerSetting() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            preloadTask?.cancel()
            translation?.stopAndReset()
        }
        .sheet(isPresented: $showsReaderSettings) {
            ReaderSettingsSheet(settings: environment.settings)
        }
        .sheet(isPresented: $showsJumpSheet) {
            ReaderJumpSheet(
                chapters: session?.chapters ?? [],
                currentChapterIndex: session?.chapterIndex ?? 0,
                pageIndex: session?.pageIndex ?? 0,
                pageCount: pages.count,
                onJumpToChapter: { jumpToChapter($0) },
                onJumpToPage: { jumpToPage($0) }
            )
        }
        .alert(L("common.notice"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: 外观

    /// 阅读区背景（跟随设置里的主题）。
    private var readerBackground: Color {
        switch environment.settings.readerTheme {
        case .system: return Color(uiColor: .systemBackground)
        case .light: return .white
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.85)
        case .dark: return Color(uiColor: .secondarySystemBackground)
        case .black: return .black
        }
    }

    /// 页面周边留白（点数）。
    private var pagePadding: CGFloat { CGFloat(environment.settings.readerPageSpacing) }

    /// 右到左阅读（日漫常见）。影响单击/滑动的方向语义。
    private var isRightToLeft: Bool {
        environment.settings.readerMode == .pagedRightToLeft
    }

    private func applyIdleTimerSetting() {
        UIApplication.shared.isIdleTimerDisabled = environment.settings.keepsScreenAwake
    }

    // MARK: 子视图

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView(L("reader.loading"))
        } else if let image = currentDisplayImage {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
                    .onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, newValue in containerSize = newValue }
            }
            .padding(pagePadding)
        } else {
            ContentUnavailableView {
                Label(L("reader.pageUnavailable.title"), systemImage: "photo")
            } description: {
                Text(L("reader.pageUnavailable.body"))
            }
        }
    }

    private var currentImage: UIImage? {
        guard let index = session?.pageIndex, let data = pageImages[index] else { return nil }
        return UIImage(data: data)
    }

    /// 实际显示的那张图：翻译开启且该页已有译文时返回译文图，否则原图。
    private var currentDisplayImage: UIImage? {
        guard let original = currentImage else { return nil }
        guard let translation, let index = session?.pageIndex else { return original }
        return translation.displayImage(for: manga, page: index, original: original) ?? original
    }

    /// 顶部提示条：翻译失败（可点掉）与额度用尽（带升级入口，**不打断阅读**）。
    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let translation, let text = translation.failureMessage {
                noticeBar(
                    text: text,
                    systemImage: "exclamationmark.triangle",
                    tint: .orange,
                    actionTitle: nil,
                    action: {}
                ) {
                    translation.dismissFailure()
                }
            }
            if let translation, let text = translation.quotaMessage {
                noticeBar(
                    text: text,
                    systemImage: "sparkles",
                    tint: .accentColor,
                    actionTitle: L("translation.quota.upgrade"),
                    action: openUpgradePage
                ) {
                    translation.dismissQuotaNotice()
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func noticeBar(
        text: String,
        systemImage: String,
        tint: Color,
        actionTitle: String?,
        action: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 打开官网购买页（外部浏览器）。App 内不接入任何支付。
    private func openUpgradePage() {
        guard let url = environment.cloudUpgradeURL else { return }
        openURL(url)
    }

    /// 单击区：左右两条窄带。方向语义与宽度**都取自 `ReaderNavigation`**——
    /// 这里不再自己算，否则「右到左的方向」「窄带该多宽」这类判断就只能靠人工点。
    private func tapZone(isLeading: Bool) -> some View {
        Color.clear
            .frame(width: CGFloat(
                ReaderNavigation.tapZoneWidth(containerWidth: Double(containerSize.width))
            ))
            .contentShape(Rectangle())
            .onTapGesture {
                advance(forward: ReaderNavigation.advancesForward(
                    tappingLeadingEdge: isLeading,
                    isRightToLeft: isRightToLeft
                ))
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            // 本章进度条 + 页码（手册 §8.2 的底栏线框图）。
            // 页码用等宽数字：翻页时数字宽度不变，整行不会左右抖。
            HStack(spacing: 8) {
                ProgressView(value: chapterProgress)
                    .progressViewStyle(.linear)
                Text(pageLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    advance(forward: false)
                } label: {
                    Label(L("reader.previousPage"), systemImage: "chevron.left")
                }
                .disabled(session == nil)

                Spacer()

                Text(session?.currentChapter?.name ?? manga.title)
                    .font(.footnote)
                    .lineLimit(1)

                Spacer()

                Button {
                    advance(forward: true)
                } label: {
                    Label(L("reader.nextPage"), systemImage: "chevron.right")
                }
                .disabled(session == nil)
            }

            if let translation, translation.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(format: L("translation.progress.remaining"), translation.remainingCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 本章阅读进度（0…1）。页数为 0 时给 0，避免除零。
    private var chapterProgress: Double {
        guard let session, !pages.isEmpty else { return 0 }
        return Double(session.pageIndex + 1) / Double(pages.count)
    }

    private var navigationTitle: String {
        session?.currentChapter?.name ?? manga.title
    }

    private var pageLabel: String {
        guard let session, !pages.isEmpty else { return "—" }
        return "\(session.pageIndex + 1) / \(pages.count)"
    }

    // MARK: 手势

    /// 拖动：未放大时横滑翻页；放大后用于平移。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                if dragStartOffset == nil { dragStartOffset = zoom.offset }
                let base = dragStartOffset ?? .zero
                zoom.setOffset(
                    CGSize(
                        width: base.width + value.translation.width,
                        height: base.height + value.translation.height
                    ),
                    containerSize: containerSize,
                    imageSize: currentImage?.size ?? .zero
                )
            }
            .onEnded { value in
                defer { dragStartOffset = nil }
                // 放大状态、位移不够、竖滑为主 → 都不翻页（规则在 `ReaderNavigation`）
                guard let forward = ReaderNavigation.forward(
                    forDragTranslation: Double(value.translation.width),
                    dy: Double(value.translation.height),
                    isZoomed: zoom.isZoomed,
                    isRightToLeft: isRightToLeft
                ) else { return }
                advance(forward: forward)
            }
    }

    /// 捏合缩放。
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBaseScale == nil { pinchBaseScale = zoom.scale }
                zoom.applyPinch(baseScale: pinchBaseScale ?? 1, factor: value.magnification)
            }
            .onEnded { _ in
                pinchBaseScale = nil
                settleZoom()
            }
    }

    private func toggleDoubleTap() {
        zoom.toggleDoubleTap()
        settleZoom()
    }

    /// 单击中央：收起 / 呼出顶栏与底栏（手册 §8.2「点中央呼出」）。
    ///
    /// 没有抽出「判定层」是刻意的：这里没有判定，只有一个开关。
    /// 硬给它编一个 `ReaderChromePolicy` 只会多一层没人读的间接。
    private func toggleChrome() {
        showsChrome.toggle()
    }

    /// 缩放变化后把位移钳制回合法范围。
    private func settleZoom() {
        zoom.setOffset(
            zoom.offset,
            containerSize: containerSize,
            imageSize: currentImage?.size ?? .zero
        )
    }

    // MARK: 跳章 / 跳页

    /// 跳到指定章（目录里点某一话）。
    ///
    /// `moveToChapter` 对「就是当前章」返回 false——此时什么都不做，
    /// 而不是重新载入一遍（重载会让当前页闪一下）。
    private func jumpToChapter(_ index: Int) {
        guard var working = session, working.moveToChapter(index) else { return }
        session = working
        Task { await loadCurrentChapter() }
    }

    /// 跳到指定页（0 基下标）。越界已在 `ReaderJump` 里钳制过。
    private func jumpToPage(_ index: Int) {
        guard var working = session else { return }
        zoom.reset()
        working.moveToPage(index, pageCount: pages.count)
        session = working
        schedulePreload(around: working.pageIndex)
        saveProgress()
        notifyTranslation()
    }

    // MARK: 下载本话

    /// 顶栏 ⤓ 的图标：跟着当前章的下载状态变，点之前就知道会发生什么。
    private var downloadIconName: String {
        switch currentChapterDownloadState {
        case .downloaded: return "arrow.down.circle.fill"
        case .active, .paused, .queued: return "stop.circle"
        case .none, .failed, .cancelled: return "arrow.down.circle"
        }
    }

    /// 当前章在下载上的状态。
    ///
    /// 复用 `ChapterDownloadState`（与章节行左滑、作品详情页同一套语义），
    /// 于是「什么状态能做什么」只有一份定义。
    private var currentChapterDownloadState: ChapterDownloadState {
        guard let chapter = session?.currentChapter else { return .none }
        if environment.isChapterDownloaded(mangaID: manga.id, chapterID: chapter.id) {
            return .downloaded
        }
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

    /// 顶栏 ⤓ 的动作：按当前状态决定「下载 / 取消 / 提示已下载」。
    private func toggleDownload() {
        guard let chapter = session?.currentChapter else { return }
        switch ChapterActionMenu.action(for: currentChapterDownloadState) {
        case .download:
            Task {
                let result = await environment.downloadChapters([chapter], of: manga)
                if let text = result.message { message = text }
            }
        case .cancel:
            Task { await environment.downloads.cancel(chapterID: chapter.id) }
        case .deleteArchive:
            // 顶栏**不做删除**：删归档在下载页与作品详情页都有确认流程，
            // 而「阅读时点一下就删掉正在看的这一话」既容易误触也没必要。
            // 这里只告诉用户「已经下好了」。
            message = L("reader.download.alreadyDone")
        }
    }

    // MARK: 行为

    /// 首次进入：读取章节、恢复进度、载入当前章。
    private func bootstrap() async {
        guard session == nil else { return }

        // 翻译编排器在这里创建（而不是作为环境单例）：它是**阅读会话级**的状态，
        // 退出阅读器就该清掉在跑的翻译，但磁盘上的译文缓存留在环境里继续复用。
        if translation == nil {
            translation = environment.makeTranslationController()
        }

        isInLibrary = libraryEntryExists()
        do {
            let chapters = try await readingSource.chapters(for: manga)
            guard !chapters.isEmpty else {
                isLoading = false
                message = L("reader.noChapters")
                return
            }
            let entry = try? environment.libraryStore.entry(mangaID: manga.id)
            var restored = ReaderSession(manga: manga, chapters: chapters)

            // 定位优先级：调用方指定的章节 > 上次读到的章节 > 第一章
            if let startChapterID,
               let index = chapters.firstIndex(where: { $0.id == startChapterID }) {
                restored.moveToChapter(index)
            } else if let chapterID = entry?.lastReadChapterID,
                      let index = chapters.firstIndex(where: { $0.id == chapterID }) {
                restored.moveToChapter(index)
                // 恢复上次读到的页码（越界会在载入章节时被钳制）
                if let page = entry?.lastReadPageIndex {
                    restored.moveToPage(page, pageCount: Int.max)
                }
            }
            session = restored
            await loadCurrentChapter()
        } catch {
            isLoading = false
            message = Self.message(for: error)
        }
    }

    /// 载入当前章的页列表与预加载窗口。
    private func loadCurrentChapter() async {
        // 注意：`guard let session` 绑定的是不可变副本，mutating 调用必须用 var 副本，
        // 改完再写回 @State。
        guard var working = session, let chapter = working.currentChapter else {
            isLoading = false
            pages = []
            pageImages = [:]
            return
        }
        isLoading = true
        do {
            let loaded = try await readingSource.pages(for: chapter, manga: manga)
            pages = loaded
            working.clampPageIndex(pageCount: loaded.count)
            session = working
            isLoading = false
            schedulePreload(around: working.pageIndex)
            saveProgress()
        } catch {
            isLoading = false
            message = Self.message(for: error)
        }
    }

    /// 调度一次预加载（先取消上一次，避免快速翻页叠起多批下载）。
    private func schedulePreload(around pageIndex: Int) {
        preloadTask?.cancel()
        preloadTask = Task { await preload(around: pageIndex) }
    }

    /// 预加载当前页前后各 N 页（N 取自设置里的预加载窗口）。
    ///
    /// 并发取图：窗口通常只有 2–4 页，直接并发即可；每页失败只跳过该页
    /// （单页挂掉不该让整章读不了）。窗口外的缓存立即释放，避免长时间阅读内存膨胀。
    private func preload(around pageIndex: Int) async {
        guard let session, let chapter = session.currentChapter, !pages.isEmpty else { return }
        let range = session.preloadRange(pageCount: pages.count, window: environment.settings.preloadWindow)
        let missing = range.filter { pageImages[$0] == nil }
        let source = readingSource
        let manga = manga

        if !missing.isEmpty {
            let targets = missing.map { ($0, pages[$0]) }
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, page) in targets {
                    group.addTask {
                        let data = try? await source.imageData(for: page, manga: manga, chapter: chapter)
                        return (index, data)
                    }
                }
                for await (index, data) in group {
                    if let data { pageImages[index] = data }
                }
            }
        }

        // 释放窗口外的缓存
        pageImages = pageImages.filter { range.contains($0.key) }

        // 图片到位后再通知翻译：翻译需要页图，早通知只会拿到空窗口
        notifyTranslation()
    }

    // MARK: 页内翻译

    /// 顶部翻译按钮：点一下开启连续翻译（当前页 + 前后几页），再点一下显示原文。
    private func toggleTranslation() {
        guard let translation, let session else { return }
        translation.toggle(
            manga: manga,
            currentPage: session.pageIndex,
            preloaded: preloadedImages(around: session.pageIndex)
        )
    }

    /// 翻页 / 图片到位后，把新进入窗口的页补进翻译队列。
    private func notifyTranslation() {
        guard let translation, let session else { return }
        translation.onVisiblePageChanged(
            manga: manga,
            currentPage: session.pageIndex,
            preloaded: preloadedImages(around: session.pageIndex)
        )
    }

    /// 取当前页附近**已加载**的页图（只取翻译窗口那么宽，别把整章都解成 UIImage）。
    private func preloadedImages(around pageIndex: Int) -> [Int: UIImage] {
        let window = environment.settings.translationPrefetchWindow
        let lower = max(0, pageIndex - window)
        let upper = pageIndex + window
        guard lower <= upper else { return [:] }
        var result: [Int: UIImage] = [:]
        for index in lower...upper {
            guard let data = pageImages[index], let image = UIImage(data: data) else { continue }
            result[index] = image
        }
        return result
    }

    private func advance(forward: Bool) {
        guard var session, !pages.isEmpty else { return }
        // 翻页时先复原缩放，避免下一页带着上一页的缩放/位移
        zoom.reset()
        let result = forward
            ? session.advanceForward(pageCount: pages.count)
            : session.advanceBackward(pageCount: pages.count)

        switch result {
        case let .moved(toPage):
            self.session = session
            schedulePreload(around: toPage)
            saveProgress()
            notifyTranslation()

        case .needsNextChapter:
            guard session.moveToNextChapter() else { return }
            self.session = session
            Task { await loadCurrentChapter() }

        case .needsPreviousChapter:
            guard session.moveToPreviousChapter() else { return }
            self.session = session
            // 回到上一章时停在**末页**，符合「往回翻」的直觉
            Task {
                await loadCurrentChapter()
                jumpToLastPageIfPossible()
            }

        case .atEnd:
            message = L("reader.atEnd")

        case .atStart:
            message = L("reader.atStart")
        }
    }

    /// 换章后跳到末页（用于「从章首回退」的场景）。
    private func jumpToLastPageIfPossible() {
        guard var working = session, !pages.isEmpty else { return }
        working.moveToLastPage(pageCount: pages.count)
        session = working
        schedulePreload(around: working.pageIndex)
        saveProgress()
    }

    /// 写回阅读进度。
    ///
    /// 只有作品在书架里才写：`updateProgress` 对不在书架的作品会抛 `entryNotFound`，
    /// 翻一页记一条失败日志既没用也吵。用户在阅读器里点星标加入书架后即开始记录。
    private func saveProgress() {
        guard isInLibrary, let mark = session?.progressMark else { return }
        do {
            try environment.libraryStore.updateProgress(
                mangaID: manga.id,
                chapterID: mark.chapterID,
                chapterName: session?.currentChapter?.name ?? "",
                pageIndex: mark.pageIndex,
                at: Date()
            )
        } catch {
            diag("ReaderView: 保存进度失败 —— \(error.localizedDescription)")
        }
    }

    // MARK: 书架

    private func libraryEntryExists() -> Bool {
        let entry: LibraryEntry? = try? environment.libraryStore.entry(mangaID: manga.id)
        return entry != nil
    }

    /// 一键加入书架：加入后进度才会被记录。
    private func addToLibrary() {
        guard environment.addToLibrary(manga) != nil else {
            message = L("source.detail.addFailed")
            return
        }
        isInLibrary = true
        message = L("source.detail.added")
        // 立刻记一次当前进度，避免用户下次进来从头开始
        saveProgress()
    }

    /// 统一错误文案：来源错误优先用自己的 `message`。
    private static func message(for error: Error) -> String {
        if let runnerError = error as? SourceRunnerError { return runnerError.message }
        if let localError = error as? LocalSourceError { return localError.message }
        return error.localizedDescription
    }
}
