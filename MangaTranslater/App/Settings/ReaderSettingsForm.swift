//
//  ReaderSettingsForm.swift
//  MangaTranslater
//
//  阅读器相关设置的**唯一实现**。
//
//  两个入口共用它：
//  1. 设置 → 阅读器；
//  2. 阅读器顶栏 ⚙（手册 §8.2 的顶栏线框图）。
//
//  为什么必须共用：这是典型的「同一个设置、两个入口」——
//  各写一份的话，下次加一个开关只会加到其中一处，于是「在阅读器里改不了主题」
//  这种问题会以「用户以为是 bug」的形式回来。共用之后，两处永远一致。
//
//  形态上只导出 `Section`，因此既能放进设置页的 `List`，也能放进弹窗的 `Form`。
//

import SwiftUI
import AppCore

struct ReaderSettingsSections: View {

    let settings: AppSettings

    var body: some View {
        Section {
            Picker(selection: Binding(
                get: { settings.readerMode },
                set: { settings.readerMode = $0 }
            )) {
                ForEach(ReaderMode.allCases, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            } label: {
                Text(L("settings.reader.mode"))
            }

            Picker(selection: Binding(
                get: { settings.readerTheme },
                set: { settings.readerTheme = $0 }
            )) {
                ForEach(ReaderTheme.allCases, id: \.self) { theme in
                    Text(theme.localizedName).tag(theme)
                }
            } label: {
                Text(L("settings.reader.theme"))
            }

            Stepper(
                String(format: L("settings.reader.pageSpacing"), settings.readerPageSpacing),
                value: Binding(
                    get: { settings.readerPageSpacing },
                    set: { settings.readerPageSpacing = $0 }
                ),
                in: AppSettings.readerPageSpacingRange
            )

            Toggle(L("settings.reader.keepAwake"), isOn: Binding(
                get: { settings.keepsScreenAwake },
                set: { settings.keepsScreenAwake = $0 }
            ))

            Stepper(
                String(format: L("settings.reader.preload"), settings.preloadWindow),
                value: Binding(
                    get: { settings.preloadWindow },
                    set: { settings.preloadWindow = $0 }
                ),
                in: AppSettings.preloadWindowRange
            )

            Stepper(
                String(format: L("settings.reader.concurrency"), settings.maxConcurrentDownloads),
                value: Binding(
                    get: { settings.maxConcurrentDownloads },
                    set: { settings.maxConcurrentDownloads = $0 }
                ),
                in: AppSettings.maxConcurrentDownloadsRange
            )
        } header: {
            Text(L("settings.section.reader"))
        } footer: {
            Text(L("settings.reader.footer"))
        }
    }
}

/// 阅读器内弹出的「阅读设置」。
///
/// 它是一个**弹窗**而不是跳回设置页：读者正在看第 300 页，
/// 想换个背景色却要退出去、改完再找回来——那是把「调整」变成「中断」。
struct ReaderSettingsSheet: View {

    let settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ReaderSettingsSections(settings: settings)
            }
            .navigationTitle(L("settings.section.reader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // 改动是立即生效的（直接写 `AppSettings`），所以这里只是关窗，
                    // 不需要「保存」——「保存」会让人以为不点就不生效。
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
    }
}
