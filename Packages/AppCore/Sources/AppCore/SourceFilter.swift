//
//  SourceFilter.swift
//  AppCore
//
//  源自定义筛选项（契约 `docs/source-api.md` §5.2）。
//
//  为什么放在 AppCore 而不是 SourceEngine：筛选项是**界面数据**——
//  宿主自动渲染搜索界面、生成默认值、判断「用户是否改了筛选」，
//  这些都不该依赖源执行引擎。SourceEngine 只负责把脚本返回的 JSON
//  解码成这里的模型。
//
//  约束：
//  - `key` 是脚本侧使用的参数名，必须非空且在同一源内唯一（宿主据此拼装
//    `getSearchManga` 的 `filters` 对象）；
//  - `select` / `sort` 必须有候选项，否则界面无从渲染，解码时会丢弃该条；
//  - `text` / `checkbox` 不接受候选项（多余候选项会被忽略而不是报错，
//    因为「字段冗余」不至于让整个搜索页不可用）。
//

import Foundation

// MARK: - 候选项

/// 下拉/排序类筛选项的一个候选项。
public struct SourceFilterOption: Hashable, Codable, Sendable, Identifiable {
    public var id: String { value }
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - 筛选项种类

/// 筛选项种类。原始值即契约里的 `type` 字段。
public enum SourceFilterKind: String, Codable, Sendable, CaseIterable {
    /// 文本输入。
    case text
    /// 勾选框。
    case checkbox
    /// 单选下拉。
    case select
    /// 排序下拉（语义与 `select` 相同，界面可差异化展示）。
    case sort

    /// 是否需要候选项列表。
    public var requiresOptions: Bool {
        switch self {
        case .select, .sort: return true
        case .text, .checkbox: return false
        }
    }
}

// MARK: - 筛选项

/// 一个源自定义筛选项。
public struct SourceFilter: Hashable, Codable, Sendable, Identifiable {
    /// 主键即 `key`：同一源内 `key` 唯一，界面用 `ForEach` 时也需要稳定标识。
    public var id: String { key }
    public let kind: SourceFilterKind
    /// 脚本侧参数名。
    public let key: String
    /// 界面展示名。
    public let name: String
    /// 候选项（`text` / `checkbox` 为空数组）。
    public let options: [SourceFilterOption]

    public init(
        kind: SourceFilterKind,
        key: String,
        name: String,
        options: [SourceFilterOption] = []
    ) {
        self.kind = kind
        self.key = key
        self.name = name
        self.options = kind.requiresOptions ? options : []
    }

    /// 界面默认选中的候选项（`select` / `sort` 取第一个；没有候选项时为 `nil`）。
    public var defaultOption: SourceFilterOption? {
        options.first
    }
}

// MARK: - 取值与默认值

extension SourceFilter {
    /// 该筛选项的默认值：文本/勾选为 `""`，下拉取第一个候选项。
    ///
    /// 「不要预设默认值」这类界面需求由调用方决定——`""` 在契约里就是
    /// 「不筛选」的合法取值（见 `docs/source-api.md` §12 的示例源）。
    public var defaultValue: String {
        defaultOption?.value ?? ""
    }
}

/// 一组筛选项的取值集合。
public typealias SourceFilterValues = [String: String]

extension Array where Element == SourceFilter {
    /// 生成默认取值集合。
    public func defaultValues() -> SourceFilterValues {
        var values: SourceFilterValues = [:]
        for filter in self {
            values[filter.key] = filter.defaultValue
        }
        return values
    }

    /// 只保留 `key` 在筛选定义内的取值。
    ///
    /// 源升级后可能删掉某些筛选项，而用户上次的取值还留在本地；
    /// 直接把旧键发给脚本会被当成「未知参数」，因此发请求前统一裁剪。
    public func sanitize(_ values: SourceFilterValues) -> SourceFilterValues {
        var sanitized: SourceFilterValues = [:]
        for filter in self {
            guard let value = values[filter.key] else { continue }
            sanitized[filter.key] = value
        }
        return sanitized
    }

    /// 是否存在重复的 `key`（宿主渲染前可据此提示源作者）。
    public var hasDuplicateKeys: Bool {
        var seen = Set<String>()
        for filter in self where !seen.insert(filter.key).inserted {
            return true
        }
        return false
    }
}
