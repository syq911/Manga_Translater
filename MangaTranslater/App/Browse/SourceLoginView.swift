//
//  SourceLoginView.swift
//  MangaTranslater
//
//  内嵌网页登录 / 人工验证（契约 §8）。
//
//  流程：用户在内嵌网页里完成登录或人机校验 → 宿主把该页面的 Cookie
//  收割到**该来源独立的容器** → 之后源脚本用 `net.*` 发请求时宿主自动带上。
//  源脚本本身不需要实现任何登录逻辑。
//
//  三个刻意的决定：
//  1. **非持久化数据存储**（`WKWebsiteDataStore.nonPersistent()`）：
//     网页会话与 App 的 `URLSession` 完全隔离，也与其他来源隔离。
//     要什么 Cookie 就显式收割什么——「网页访问过的全部站点」
//     不该悄悄进入 App 的任何容器。
//  2. **收割按主机过滤**：登录过程会顺带访问 CDN 与第三方登录域，
//     全收等于把别的站点的凭据一起交出去（规则见 `CookieHarvest`）。
//  3. **没有「自动完成」**：不猜测用户什么时候登录成功——
//     让用户点「完成」。自动判断（例如「出现了某某 Cookie」）在真实站点上
//     基本不可靠，还会在用户还没输完的时候抢走页面。
//

import SwiftUI
import WebKit
import AppCore
import ComicNet
import SourceEngine

/// 打开网页的目的（只影响文案）。
enum WebLoginPurpose {
    case login
    case verification

    var title: String {
        switch self {
        case .login: return L("login.title")
        case .verification: return L("verify.title")
        }
    }

    var footer: String {
        switch self {
        case .login: return L("login.footer")
        case .verification: return L("verify.footer")
        }
    }
}

/// 内嵌网页的宿主。
@MainActor
@Observable
final class WebLoginModel: NSObject, WKNavigationDelegate {

    let startURL: URL
    private(set) var isLoading = true
    private(set) var lastError: String?
    /// 当前所在地址（收割时按它的主机过滤）。
    private(set) var currentURL: URL?

    let webView: WKWebView

    init(startURL: URL) {
        self.startURL = startURL
        let configuration = WKWebViewConfiguration()
        // 非持久化：网页会话与 App 的其他网络栈、其他来源互不可见
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: startURL))
    }

    /// 收割当前网页的全部 Cookie（已按主机过滤前的原始集合）。
    func harvestCookies() async -> [HarvestedCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                // `HTTPCookie.properties` 是 Optional（Swift 侧签名如此），
                // 解不开时给空字典——`HarvestedCookie` 对缺失字段有兜底。
                continuation.resume(
                    returning: cookies.map { HarvestedCookie(properties: $0.properties ?? [:]) }
                )
            }
        }
    }

    /// 收割时使用的主机：优先当前页面，其次起始地址。
    var harvestHost: String? {
        (currentURL ?? startURL).host?.lowercased()
    }

    func reload() {
        lastError = nil
        webView.load(URLRequest(url: startURL))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        lastError = nil
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        // 用户主动取消（例如点了别的链接）不该报成错误
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        lastError = error.localizedDescription
    }
}

/// `WKWebView` 的 SwiftUI 包装。
///
/// 直接复用模型里那一个 `WKWebView`（而不是每次重建）：
/// 重建会让页面重新加载，用户刚输的内容就没了。
private struct WebViewContainer: UIViewRepresentable {

    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 页面

struct SourceLoginView: View {

    let sourceID: SourceID
    let sourceName: String
    let url: URL
    let purpose: WebLoginPurpose

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: WebLoginModel?
    @State private var message: String?
    @State private var isHarvesting = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    WebViewContainer(webView: model.webView)
                        .overlay(alignment: .top) {
                            if model.isLoading {
                                ProgressView()
                                    .padding(8)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(.top, 8)
                            }
                        }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
            .navigationTitle(purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("login.done")) {
                        Task { await finish() }
                    }
                    .disabled(isHarvesting)
                }
            }
            .alert(L("common.notice"), isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button(L("common.ok")) { dismiss() }
            } message: {
                Text(message ?? "")
            }
            .task {
                if model == nil { model = WebLoginModel(startURL: url) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(purpose.footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = model?.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                Text(sourceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model?.lastError != nil {
                    Button(L("source.retry")) { model?.reload() }
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: 收割

    private func finish() async {
        guard let model else { dismiss(); return }
        isHarvesting = true
        defer { isHarvesting = false }

        let cookies = await model.harvestCookies()
        let written = CookieHarvest.merge(
            cookies,
            into: environment.cookieJar,
            sourceID: sourceID,
            forHost: model.harvestHost
        )
        // 落盘失败不打断用户：容器已经写好了，最坏情况是重启后要重新登录一次
        try? environment.cookieJar.persist()
        // `diag` 是 AppCore 里的全局函数，不是 AppEnvironment 的方法
        diag("SourceLoginView: 来源 \(sourceID.rawValue) 收割 Cookie \(written) 条")

        if written == 0 {
            // 明确告知「没有收割到」，而不是让用户以为成功了
            message = L("login.noCookies")
        } else {
            message = String(format: L("login.saved"), written)
        }
    }
}

#Preview {
    SourceLoginView(
        sourceID: SourceID("demo"),
        sourceName: "示例源",   // i18n-exempt：预览用的中性示例数据
        url: URL(string: "https://example.com")!,
        purpose: .login
    )
    .environment(AppEnvironment.makeDefault())
}
