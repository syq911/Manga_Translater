//
//  BackgroundExecutionKeeper.swift
//  MangaTranslater
//
//  后台执行断言：让下载在用户离开 App 后再跑一会儿。
//
//  iOS 不会让普通进程在后台一直运行。App 退到后台后系统只给很短的时间
//  （通常几十秒，用满之前必须调用 `endBackgroundTask`，否则会被强杀）。
//  `beginBackgroundTask` 就是向系统申请这段时间。
//
//  为什么不用 `URLSession` 的后台传输：
//  那条路要求「取页」整条链路由系统进程驱动，而本项目的下载是
//  「脚本先算页列表 → 宿主逐页抓取 → 打包成 CBZ」（契约 §5.3），
//  中间有 JS 沙箱与文件打包，没法拆给系统进程。
//  所以现实做法是：**能多跑一会儿就跑一会儿**，并在界面上明确告知
//  「剩下的要在前台完成」——而不是假装能后台无限下载。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class BackgroundExecutionKeeper {

    #if canImport(UIKit)
    private var token: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// 申请开始一段时间（重复调用是幂等的）。
    ///
    /// - Parameter onExpire: 系统收回时间时调用。**必须**在这里结束工作，
    ///   否则进程会被强杀——强杀会丢掉「已抓取的页」，白下载一场。
    func begin(name: String, onExpire: (() -> Void)? = nil) {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        guard token == .invalid else { return }
        let application = UIApplication.shared
        token = application.beginBackgroundTask(withName: name) { [weak self] in
            // 到期回调可能在任意线程，回到主线程收拾
            Task { @MainActor in
                onExpire?()
                self?.end()
            }
        }
        #endif
    }

    /// 归还时间。已经归还过或从未申请时什么都不做（避免重复 end 触发断言）。
    func end() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        guard token != .invalid else { return }
        let application = UIApplication.shared
        let current = token
        token = .invalid
        application.endBackgroundTask(current)
        #endif
    }

    /// 当前是否持有后台时间。
    var isActive: Bool {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        return token != .invalid
        #else
        return false
        #endif
    }
}
