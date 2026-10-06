//
//  SourceVersionTests.swift
//  MangaTranslaterTests
//
//  来源版本号的解析与比较。
//
//  为什么值得单独测：更新提示是用户唯一能感知「源有新版」的入口，
//  而字符串比较会给出反直觉的结果（`"1.10" < "1.9"`）。这里的用例把
//  边界钉死：缺段补零、预发布后缀、非法版本号一律「不提示更新」。
//

import Testing
import Foundation
import AppCore
@testable import SourceEngine

@Suite("来源版本号")
struct SourceVersionTests {

    @Test("解析：核心数字段与预发布后缀")
    func parsesComponents() throws {
        let version = try #require(SourceVersion("1.2.3"))
        #expect(version.components == [1, 2, 3])
        #expect(version.preRelease == nil)
        #expect(version.raw == "1.2.3")

        let pre = try #require(SourceVersion("2.0.0-beta.1"))
        #expect(pre.components == [2, 0, 0])
        #expect(pre.preRelease == "beta.1")

        let short = try #require(SourceVersion("7"))
        #expect(short.components == [7])
    }

    @Test("解析：首尾空白被忽略，非法版本号返回 nil")
    func rejectsInvalidVersions() {
        #expect(SourceVersion(" 1.0.0 ")?.raw == "1.0.0")
        #expect(SourceVersion("") == nil)
        #expect(SourceVersion("v1.0.0") == nil)
        #expect(SourceVersion("1.0.0.0") == nil)
        #expect(SourceVersion("1..0") == nil)
    }

    @Test("比较：缺段按 0 补齐")
    func comparesWithPadding() {
        #expect(SourceVersion("1.2") == SourceVersion("1.2.0"))
        #expect(SourceVersion.isNewer("1.2.1", than: "1.2"))
        #expect(SourceVersion.isNewer("1.2", than: "1.2.0") == false)
    }

    @Test("比较：不是字符串序")
    func comparesNumerically() {
        // 字符串比较会认为 "1.10" < "1.9"，这里必须是 1.10 更新
        #expect(SourceVersion.isNewer("1.10", than: "1.9"))
        #expect(SourceVersion.isNewer("1.9", than: "1.10") == false)
        #expect(SourceVersion.isNewer("2", than: "10") == false)
    }

    @Test("比较：正式版高于同号的预发布版")
    func prefersReleaseOverPrerelease() {
        #expect(SourceVersion.isNewer("1.0.0", than: "1.0.0-beta"))
        #expect(SourceVersion.isNewer("1.0.0-beta", than: "1.0.0") == false)
        #expect(SourceVersion.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1"))
    }

    @Test("比较：无法解析时一律「不提示更新」")
    func refusesToGuessOnInvalidInput() {
        // 宁可漏提示，也不让用户反复看到装不上的「新版本」
        #expect(SourceVersion.isNewer("乱写", than: "1.0.0") == false)
        #expect(SourceVersion.isNewer("1.1.0", than: "乱写") == false)
    }

    @Test("比较：可以排序")
    func sortsAscending() {
        let raw = ["1.10", "1.2", "1.2.1", "0.9", "2.0.0-alpha"]
        let versions = raw.compactMap { SourceVersion($0) }
        let sorted = versions.sorted().map(\.raw)
        #expect(sorted == ["0.9", "1.2", "1.2.1", "1.10", "2.0.0-alpha"])
    }
}
