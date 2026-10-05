//
//  AppEnvironment.swift
//  MangaTranslater
//
//  应用级依赖容器。集中持有设置、源仓库、Cookie、诊断日志等单例资源，
//  通过 SwiftUI Environment 下发给各视图，避免视图各自 new 一份。
//

import Foundation
import Observation
import AppCore
import ComicNet
import SourceEngine
import ComicDownload

@MainActor
@Observable
final class AppEnvironment {

    let settings: AppSettings
    let sourceStore: SourceStore
    let cookieJar: CookieJar
    let diagnostics: DiagnosticsLog

    /// 应用数据根目录（Application Support/MangaTranslater）。
    let dataDirectory: URL

    init(
        settings: AppSettings,
        sourceStore: SourceStore,
        cookieJar: CookieJar,
        diagnostics: DiagnosticsLog,
        dataDirectory: URL
    ) {
        self.settings = settings
        self.sourceStore = sourceStore
        self.cookieJar = cookieJar
        self.diagnostics = diagnostics
        self.dataDirectory = dataDirectory
    }

    /// 按默认路径构建。任一步失败都退回到临时目录，保证 App 一定能启动。
    static func makeDefault() -> AppEnvironment {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("MangaTranslater", isDirectory: true)

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            diag("AppEnvironment: 无法创建数据目录，退回临时目录 —— \(error.localizedDescription)")
        }

        let settings = AppSettings()
        let sourceStore = SourceStore(rootDirectory: root.appendingPathComponent("SourcesRoot", isDirectory: true))
        let cookieJar = CookieJar(storageURL: root.appendingPathComponent("cookies.json", isDirectory: false))

        diag("AppEnvironment: 启动，数据目录 = \(root.path)")
        return AppEnvironment(
            settings: settings,
            sourceStore: sourceStore,
            cookieJar: cookieJar,
            diagnostics: .shared,
            dataDirectory: root
        )
    }

    /// 已在设置页与浏览页重复使用的「已安装源」快照。
    var installedSources: [InstalledSource] {
        sourceStore.installedSources()
    }

    /// 已添加的源仓库（出厂为空）。
    var repositories: [String] {
        sourceStore.repositories
    }
}
