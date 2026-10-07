//
//  NetworkError.swift
//  ComicNet
//
//  网络层错误。与 `AppError` 可互相映射，便于 UI 统一处理。
//

import Foundation
import AppCore

public enum NetworkError: Error, Equatable, Sendable {
    /// URL 非法或 scheme 不受支持。
    case invalidURL(String)
    /// 请求超时。
    case timeout(seconds: Int)
    /// 设备离线。
    case offline
    /// HTTP 状态码异常。`retryAfterSeconds` 来自 `Retry-After` 头（若有）。
    case httpStatus(code: Int, retryAfterSeconds: Int?)
    /// 响应体超过上限。
    case responseTooLarge(limit: Int)
    /// 解析失败。
    case decoding(String)
    /// 传输层错误（连接中断、TLS 失败等）。
    case transport(String)
    /// 请求被取消。
    case cancelled
}

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return Copy.format("error.net.invalidURL", value)
        case let .timeout(seconds):
            return Copy.format("error.net.timeout", seconds)
        case .offline:
            return Copy.text("error.net.offline")
        case let .httpStatus(code, retryAfter):
            if let retryAfter {
                return Copy.format("error.net.httpStatusRetry", code, retryAfter)
            }
            return Copy.format("error.net.httpStatus", code)
        case let .responseTooLarge(limit):
            return Copy.format("error.net.responseTooLarge", limit)
        case let .decoding(reason):
            return Copy.format("error.net.decoding", reason)
        case let .transport(reason):
            return Copy.format("error.net.transport", reason)
        case .cancelled:
            return Copy.text("error.net.cancelled")
        }
    }
}

extension NetworkError {
    /// 是否值得重试。4xx（除 408 / 429）不重试。
    public var isRetryable: Bool {
        switch self {
        case .timeout, .offline, .transport:
            return true
        case let .httpStatus(code, _):
            return code == 408 || code == 429 || (500...599).contains(code)
        case .invalidURL, .responseTooLarge, .decoding, .cancelled:
            return false
        }
    }

    /// 是否属于「来源侧限流」，用于提示用户降低频率。
    public var isRateLimited: Bool {
        if case let .httpStatus(code, _) = self, code == 429 { return true }
        return false
    }

    public var toAppError: AppError {
        switch self {
        case let .invalidURL(value): return .invalidInput(Copy.format("error.net.payloadURL", value))
        case let .timeout(seconds): return .network("timeout(\(seconds)s)")
        case .offline: return .network("offline")
        case let .httpStatus(code, _): return .network("http \(code)")
        case let .responseTooLarge(limit): return .invalidInput(Copy.format("error.net.payloadTooLarge", limit))
        case let .decoding(reason): return .unknown("decode: \(reason)")
        case let .transport(reason): return .network(reason)
        case .cancelled: return .cancelled
        }
    }
}
