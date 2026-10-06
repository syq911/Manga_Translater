//
//  QuotaPolicy.swift
//  MangaTranslater
//
//  免费额度的**纯计算**部分：重置时刻、剩余比例、文案。
//
//  额度本身由服务端记账（客户端不可能可信地统计页数，也不该尝试）。
//  这里只算两件与「时间」有关、且完全可以离线断言的事：
//
//  1. **何时重置**：《开发手册》7.2 规定按自然日 UTC+8 重置，
//     「纯时间戳计算，无需定时任务」。于是重置时刻 = 东八区的次日零点。
//     客户端算它只是为了显示「明天 00:00 重置」，不参与记账。
//  2. **剩余量的表达**：把「剩余 8 / 上限 10」变成界面上的一句人话。
//
//  用固定的东八区日历而不是设备时区：额度是按东八日切的，
//  旅行到别的时区不该让「今天还剩几页」跟着变。
//

import Foundation
import AppCore

enum QuotaPolicy {

    /// 每日免费额度（页）。与服务端保持一致，仅用于展示。
    static let freeDailyLimit = 10
    /// 订阅用户的公平使用软上限（页/月），由服务端执行。
    static let subscriptionSoftMonthlyLimit = 3000

    /// 东八区日历（额度按北京时间自然日切分）。
    static let quotaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // `TimeZone(identifier:)` 对 "Asia/Shanghai" 在 iOS 上一定存在；
        // 万一拿不到就退到固定 +8 偏移，绝不因为时区部件缺失而崩。
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")
            ?? TimeZone(secondsFromGMT: 8 * 3600)
            ?? TimeZone.current
        return calendar
    }()

    /// 下一次额度重置时刻（东八区次日零点）。
    static func nextReset(after date: Date) -> Date {
        let startOfDay = quotaCalendar.startOfDay(for: date)
        return quotaCalendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(24 * 3600)
    }

    /// 默认的额度重置时刻（epoch 秒），用于「还没拿到服务端快照」时的占位。
    static func defaultResetEpoch(now: Date = Date()) -> Int {
        Int(nextReset(after: now).timeIntervalSince1970)
    }

    /// 剩余量占上限的比例（0...1）。上限非正时返回 0。
    static func remainingFraction(remaining: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        let clamped = min(max(0, remaining), limit)
        return Double(clamped) / Double(limit)
    }

    /// 额度是否已用尽。
    static func isExhausted(remaining: Int) -> Bool {
        remaining <= 0
    }

    /// 把某个时刻格式化成东八区的「时:分」（用于「明天 00:00 重置」）。
    static func resetDescription(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = quotaCalendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 把「还剩多少」压成一句界面文案。
    static func summary(account: CloudAccount) -> String {
        if account.isPro {
            return L("cloud.quota.unlimited")
        }
        if isExhausted(remaining: account.remainingToday) {
            return String(format: L("cloud.quota.exhausted"), resetDescription(for: account.quotaResetDate))
        }
        return String(format: L("cloud.quota.remaining"), account.remainingToday, account.dailyLimit)
    }
}
