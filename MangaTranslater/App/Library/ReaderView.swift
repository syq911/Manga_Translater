//
//  ReaderView.swift
//  MangaTranslater
//
//  阅读器（M1 范围：本地文件源）。
//
//  职责划分：
//  - 翻页/翻章/预加载范围的**规则**在 `AppCore.ReaderSession`（可单元测试）；
//  - 缩放/平移的**规则**在 `AppCore.ZoomState`（可单元测试）；
//  - 本视图只做三件事：把当前页画出来、把手势转成「前进/后退/缩放」、把进度写回书架。
//
//  远程源的页加载会在 M2 接入（走 `PageDataProviding` 的异步实现），
//  本地源因为数据就在沙盒里，直接同步读取即可。
//

import SwiftUI
import UIKit
import AppCore
import SourceEngine

struct ReaderView: View {

    let manga: Manga

    @Environment(AppEnvironment.self) private var environment

    @State private var session: ReaderSession?
    @State private var pages: [ComicPage] = []
    @State private var pageImages: [Int: Data] = [:]
    @State private var message: String?
    @State private var isLoading = true

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
            .onTapGesture(count: 2) { toggleDoubleTap() }
            .overlay(alignment: .leading) { tapZone(isLeading: true) }
            .overlay(alignment: .trailing) { tapZone(isLeading: false) }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)

            bottomBar
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { bootstrap() }
        .onAppear { applyIdleTimerSetting() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
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
            ProgressView("载入中…")
        } else if let image = currentImage {
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
                Label("这一页打不开", systemImage: "photo")
            } description: {
                Text("可能归档损坏或该页不是有效图片。")
            }
        }
    }

    private var currentImage: UIImage? {
        guard let index = session?.pageIndex, let data = pageImages[index] else { return nil }
        return UIImage(data: data)
    }

    /// 单击区：左右两条窄带。方向语义随阅读方向变化。
    private func tapZone(isLeading: Bool) -> some View {
        Color.clear
            .frame(width: 60)
            .contentShape(Rectangle())
            .onTapGesture {
                // 左到右：左侧=上一页；右到左：左侧=下一页
                let forward = isRightToLeft ? isLeading : !isLeading
                advance(forward: forward)
            }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                advance(forward: false)
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(session == nil)

            Spacer()

            VStack(spacing: 2) {
                Text(session?.currentChapter?.name ?? manga.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(pageLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                advance(forward: true)
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(session == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
                guard !zoom.isZoomed else { return }   // 放大状态只平移，不翻页

                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) > 40 else { return }
                let swipedLeft = dx < 0
                // 左滑在「左到右」模式是下一页；在「右到左」模式是上一页
                let forward = isRightToLeft ? !swipedLeft : swipedLeft
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

    /// 缩放变化后把位移钳制回合法范围。
    private func settleZoom() {
        zoom.setOffset(
            zoom.offset,
            containerSize: containerSize,
            imageSize: currentImage?.size ?? .zero
        )
    }

    // MARK: 行为

    /// 首次进入：读取章节、恢复进度、载入当前章。
    private func bootstrap() {
        guard session == nil else { return }
        do {
            let chapters = try environment.localSource.chapters(for: manga)
            let entry = try? environment.libraryStore.entry(mangaID: manga.id)
            var restored = ReaderSession(manga: manga, chapters: chapters)
            if let chapterID = entry?.lastReadChapterID,
               let index = chapters.firstIndex(where: { $0.id == chapterID }) {
                restored.moveToChapter(index)
                // 恢复上次读到的页码（越界会在载入章节时被钳制）
                if let page = entry?.lastReadPageIndex {
                    restored.moveToPage(page, pageCount: Int.max)
                }
            }
            session = restored
            loadCurrentChapter()
        } catch {
            isLoading = false
            message = (error as? LocalSourceError)?.message ?? error.localizedDescription
        }
    }

    /// 载入当前章的页列表与预加载窗口。
    private func loadCurrentChapter() {
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
            let loaded = try environment.localSource.pages(for: chapter, manga: manga)
            pages = loaded
            working.clampPageIndex(pageCount: loaded.count)
            session = working
            preload(around: working.pageIndex)
            isLoading = false
            saveProgress()
        } catch {
            isLoading = false
            message = (error as? LocalSourceError)?.message ?? error.localizedDescription
        }
    }

    /// 预加载当前页前后各 N 页（N 取自设置里的预加载窗口）。
    private func preload(around pageIndex: Int) {
        guard let session, !pages.isEmpty else { return }
        let range = session.preloadRange(pageCount: pages.count, window: environment.settings.preloadWindow)
        for index in range where pageImages[index] == nil {
            if let data = try? environment.localSource.imageDataSync(for: pages[index], manga: manga) {
                pageImages[index] = data
            }
        }
        // 释放窗口外的缓存，避免长时间阅读内存膨胀
        let keep = range
        pageImages = pageImages.filter { keep.contains($0.key) }
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
            preload(around: toPage)
            saveProgress()

        case .needsNextChapter:
            guard session.moveToNextChapter() else { return }
            self.session = session
            loadCurrentChapter()

        case .needsPreviousChapter:
            guard session.moveToPreviousChapter() else { return }
            self.session = session
            // 回到上一章时停在**末页**，符合「往回翻」的直觉
            loadCurrentChapter()
            jumpToLastPageIfPossible()

        case .atEnd:
            message = "已经是最后一页了。"

        case .atStart:
            message = "已经是第一页了。"
        }
    }

    /// 换章后跳到末页（用于「从章首回退」的场景）。
    private func jumpToLastPageIfPossible() {
        guard var working = session, !pages.isEmpty else { return }
        working.moveToLastPage(pageCount: pages.count)
        session = working
        preload(around: working.pageIndex)
        saveProgress()
    }

    /// 写回阅读进度（失败只提示，不打断阅读）。
    private func saveProgress() {
        guard let mark = session?.progressMark else { return }
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
}
