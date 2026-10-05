//
//  AppError.swift
//  AppCore
//
//  应用统一错误类型。所有模块对外抛出的错误都应能映射到这里的某个 case，
//  以便 UI 层统一展示、区分「可重试」与「不可重试」。
//

import Foundation

/// 应用统一错误。
public enum AppError: Error, Equatable, Sendable {
    /// 调用方传入了非法参数（空字符串、越界数值、格式不合法等）。
    case invalidInput(String)
    /// 找不到目标资源（文件、记录、源等）。
    case notFound(String)
    /// 文件系统相关失败（读、写、权限、磁盘满）。
    case fileSystem(String)
    /// 网络相关失败（超时、连接中断、HTTP 状态异常）。
    case network(String)
    /// 当前环境不支持该能力（例如设备缺失某个 API）。
    case unsupported(String)
    /// 操作被主动取消（用户操作或任务丢弃）。
    case cancelled
    /// 未归类的错误。
    case unknown(String)
}

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidInput(reason):
            return "输入不合法：\(reason)"
        case let .notFound(what):
            return "找不到内容：\(what)"
        case let .fileSystem(reason):
            return "文件操作失败：\(reason)"
        case let .network(reason):
            return "网络请求失败：\(reason)"
        case let .unsupported(what):
            return "当前环境不支持：\(what)"
        case .cancelled:
            return "操作已取消"
        case let .unknown(reason):
            return "未知错误：\(reason)"
        }
    }

    /// 稳定的机器可读错误码，便于日志聚合与测试断言。
    public var code: String {
        switch self {
        case .invalidInput: return "invalid_input"
        case .notFound: return "not_found"
        case .fileSystem: return "file_system"
        case .network: return "network"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }

    /// 是否值得重试。取消、参数非法、不支持一律不重试。
    public var isRetryable: Bool {
        switch self {
        case .network, .fileSystem:
            return true
        case .invalidInput, .notFound, .unsupported, .cancelled, .unknown:
            return false
        }
    }
}

extension AppError {
    /// 把任意 `Error` 归一化为 `AppError`；已经是 `AppError` 时原样返回。
    public static func normalize(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        if error is CancellationError {
            return .cancelled
        }
        let nsError = error as NSError
        switch nsError.domain {
        case NSURLErrorDomain:
            return .network("\(nsError.code)")
        case NSCocoaErrorDomain:
            return .fileSystem("\(nsError.code)")
        default:
            return .unknown(nsError.localizedDescription)
        }
    }
}
