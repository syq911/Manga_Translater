//
//  SourceRunner.swift
//  SourceEngine
//
//  源 API 契约（以代码形式固化）与执行期沙箱配置。
//
//  契约 v1 的七个方法名在此冻结；脚本是否实现某个方法由
//  `SourceAPIContract.missingMethods(in:)` 做静态预检，
//  真正的执行由 `SourceRuntimeExecuting` 的实现（M2 接入 JavaScriptCore）负责。
//
//  沙箱约束（来自开发手册）：
//  - 单次调用超时 10 秒；
//  - 脚本无法访问文件系统 / 钥匙串 / 其他来源的数据；
//  - 网络请求必须经由 `net` 桥接（自动带上该来源的 Cookie 与节流）。
//

import Foundation
import AppCore

/// 源 API 方法。
public enum SourceAPIMethod: String, CaseIterable, Sendable {
    case popularManga = "getPopularManga"
    case latestUpdates = "getLatestUpdates"
    case searchManga = "getSearchManga"
    case mangaDetails = "getMangaDetails"
    case chapterList = "getChapterList"
    case pageList = "getPageList"
    case filters = "getFilters"

    /// 必需实现的方法。
    public var isRequired: Bool {
        switch self {
        case .popularManga, .searchManga, .mangaDetails, .chapterList, .pageList:
            return true
        case .latestUpdates, .filters:
            return false
        }
    }

    /// 该方法在脚本中的函数签名片段（用于静态预检）。
    public var functionPatterns: [String] {
        ["function \(rawValue)(", "\(rawValue) = function", "\(rawValue): function", "\(rawValue) = async", "const \(rawValue) = "]
    }
}

/// 源 API 契约本体。
public enum SourceAPIContract {

    /// 契约版本。
    public static let version = "1.0"

    /// 必需方法。
    public static var requiredMethods: [SourceAPIMethod] {
        SourceAPIMethod.allCases.filter(\.isRequired)
    }

    /// 可选方法。
    public static var optionalMethods: [SourceAPIMethod] {
        SourceAPIMethod.allCases.filter { !$0.isRequired }
    }

    /// 脚本中缺失的必需方法。
    public static func missingMethods(in script: String) -> [SourceAPIMethod] {
        requiredMethods.filter { method in
            !method.functionPatterns.contains { script.contains($0) }
        }
    }

    /// 静态预检：脚本是否实现了全部必需方法。
    public static func isComplete(_ script: String) -> Bool {
        missingMethods(in: script).isEmpty
    }
}

/// 源执行错误。
public enum SourceRunnerError: Error, Equatable {
    case notInstalled(String)
    case incompleteContract(missing: [String])
    case scriptRejected(String)
    case executionTimeout(seconds: Int)
    case executionFailed(String)
    case invalidResponse(String)
    case cancelled

    public var message: String {
        switch self {
        case let .notInstalled(key):
            return "源未安装：\(key)"
        case let .incompleteContract(missing):
            return "源未实现必需方法：\(missing.joined(separator: ", "))"
        case let .scriptRejected(reason):
            return "源脚本被拒绝：\(reason)"
        case let .executionTimeout(seconds):
            return "源执行超时（\(seconds) 秒）"
        case let .executionFailed(reason):
            return "源执行失败：\(reason)"
        case let .invalidResponse(reason):
            return "源返回数据不合法：\(reason)"
        case .cancelled:
            return "源调用已取消"
        }
    }
}

extension SourceRunnerError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 执行期沙箱配置。
public struct SourceRuntimeConfiguration: Equatable, Sendable {
    /// 单次调用超时（秒）。
    public var callTimeoutSeconds: Int
    /// 单个来源是否允许发起网络请求。
    public var allowsNetworking: Bool
    /// 单次调用可返回的最大字节数。
    public var maxResponseBytes: Int

    public init(
        callTimeoutSeconds: Int = 10,
        allowsNetworking: Bool = true,
        maxResponseBytes: Int = 4 * 1024 * 1024
    ) {
        self.callTimeoutSeconds = max(1, callTimeoutSeconds)
        self.allowsNetworking = allowsNetworking
        self.maxResponseBytes = max(1024, maxResponseBytes)
    }
}

/// 源脚本执行器抽象。M2 将由 JavaScriptCore 实现。
public protocol SourceRuntimeExecuting: Sendable {
    /// 载入脚本（实现方负责创建独立沙箱，不得与其他来源共享全局状态）。
    func load(script: String, meta: SourceScriptMeta) async throws

    /// 调用契约方法，返回 JSON 字符串（由上层解码为模型）。
    func call(_ method: SourceAPIMethod, arguments: [String]) async throws -> String

    /// 释放沙箱资源。
    func teardown() async
}
