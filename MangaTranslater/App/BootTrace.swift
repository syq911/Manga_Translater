//
//  BootTrace.swift
//  MangaTranslater
//
//  启动轨迹：把「启动走到了哪一步」落到 Documents/boot.log。
//
//  为什么需要它：
//  本项目在真机上出现过「启动即闪退」，而模拟器与 CI 都复现不出来——
//  单元测试是以 App 为测试宿主跑的（997 个用例全绿），说明 App 在模拟器里
//  能正常启动；模拟器不校验代码签名，真机校验。于是「模拟器好、真机崩」
//  这个组合本身就说明问题出在真机专属的那一层。
//
//  这一层里，崩溃日志不一定存在：进程若在加载阶段就被系统终止
//  （签名校验失败、dyld 找不到符号），系统常常不生成 crash report。
//  此时唯一能拿到的事实是「我们的代码到底有没有跑起来」——
//  于是需要一条自己写的、不依赖任何基础设施的痕迹。
//
//  刻意不用既有设施（它们各自都可能正是要排查的对象）：
//  - 不用 `DiagnosticsLog`：它有轮转、有 DateFormatter、有自己的目录选择；
//  - 不用 `Copy`：文案表在资源包里，而「资源包是否可用」本身就在排查清单上；
//  - 不抛错、不打印、不中断流程，任何失败一律静默。
//
//  落点选 Documents：`UIFileSharingEnabled` 已开启，用户可以在
//  「文件」App → 我的 iPhone → MangaTranslater 里直接看到并取走这个文件，
//  不需要连电脑、不需要 Xcode。
//
//  读法（两句话就能定性）：
//  - 文件不存在 / 一行都没有 → 进程没跑到我们的代码，属于加载或签名层；
//  - 停在中间某一行          → 就是那一行之后崩的，范围缩到单个构造调用；
//  - 一直写到 "rootView.shown" 之后才崩 → 崩在首屏渲染或之后，与启动无关。
//

import Foundation

/// 极简启动打点。开销只在启动期，几次文件追加，之后不再调用。
enum BootTrace {

    /// 每次进程只保留**这一次**启动的轨迹：首次写入覆盖旧文件，之后追加。
    /// 否则多次启动的痕迹叠在一起，反而看不出「这次停在哪儿」。
    private static var hasTruncated = false
    private static let lock = NSLock()

    /// 记一步。步骤名用英文短标识：它出现在文件里，也出现在日志抓取脚本里，
    /// 保持 ASCII 便于在不同终端与工具间复制粘贴。
    static func mark(_ step: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }

        let url = base.appendingPathComponent("boot.log")
        let line = "\(stamp())  \(step)\n"
        guard let data = line.data(using: .utf8) else { return }

        guard hasTruncated else {
            hasTruncated = true
            // 覆盖写：新一次启动从干净的轨迹开始
            try? data.write(to: url, options: .atomic)
            return
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 文件句柄拿不到（例如已被覆盖策略删掉）时退回整体重写
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 自带时间戳，不共用 `DiagnosticsLog` 的 formatter（那是要排查的对象之一）。
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
