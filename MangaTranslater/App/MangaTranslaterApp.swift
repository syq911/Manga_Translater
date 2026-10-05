//
//  MangaTranslaterApp.swift
//  MangaTranslater
//
//  应用入口。
//

import SwiftUI

@main
struct MangaTranslaterApp: App {

    @State private var environment = AppEnvironment.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}
