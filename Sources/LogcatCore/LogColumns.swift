import Foundation

public enum LogColumn: String, CaseIterable, Identifiable {
    case level, time, tag, pid, message
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .level: return "等级"
        case .time: return "时间"
        case .tag: return "Tag"
        case .pid: return "PID"
        case .message: return "消息"
        }
    }
}

/// Keep a useful table even if saved settings are stale or malformed.
public struct LogColumnVisibility {
    private let defaults: UserDefaults
    private static let key = "logs.visibleColumns"
    public private(set) var visibleColumns: [LogColumn]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.key).map { Set($0.compactMap(LogColumn.init(rawValue:))) }
        let known = LogColumn.allCases.filter { saved?.contains($0) ?? true }
        visibleColumns = known.isEmpty ? LogColumn.allCases : known
    }
    public func contains(_ column: LogColumn) -> Bool { visibleColumns.contains(column) }
    public func canToggle(_ column: LogColumn) -> Bool { !contains(column) || visibleColumns.count > 1 }
    public mutating func setVisible(_ column: LogColumn, _ visible: Bool) {
        guard visible != contains(column), visible || visibleColumns.count > 1 else { return }
        var selected = Set(visibleColumns)
        if visible { selected.insert(column) } else { selected.remove(column) }
        visibleColumns = LogColumn.allCases.filter { selected.contains($0) }
        save()
    }
    public mutating func reset() { visibleColumns = LogColumn.allCases; save() }
    private func save() { defaults.set(visibleColumns.map(\.rawValue), forKey: Self.key) }
}
