import Foundation

public struct SavedLogFilter: Codable, Hashable, Identifiable {
    public var query: String
    public var tag: String
    public var regex: Bool
    public var minimum: Int
    public var id: Self { self }

    public init(query: String, tag: String = "", regex: Bool = false, minimum: Int = 0) {
        self.query = regex ? query : query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.regex = regex; self.minimum = minimum
    }
    public var canSave: Bool {
        guard (0..<LogLevel.allCases.count).contains(minimum),
              !query.isEmpty || !tag.isEmpty || minimum > 0 else { return false }
        return !regex || (try? NSRegularExpression(pattern: query, options: .caseInsensitive)) != nil
    }
    public var title: String {
        var parts = [query.isEmpty ? "全部消息" : query.replacingOccurrences(of: "\n", with: " ")]
        if !tag.isEmpty { parts.append("Tag: " + tag) }
        if minimum > 0, minimum < LogLevel.allCases.count { parts.append(LogLevel.allCases[minimum].title + "+") }
        if regex { parts.append("正则") }
        return parts.joined(separator: " · ")
    }
}

public struct FilterHistoryEntry: Codable, Identifiable, Equatable {
    public var filter: SavedLogFilter
    public var favorite: Bool
    public var id: SavedLogFilter { filter }
}

/// Records completed edits, not each intermediate keystroke. Favorites do not expire.
public struct FilterHistory {
    private let defaults: UserDefaults
    private static let key = "logFilterHistory.v1"
    public private(set) var entries: [FilterHistoryEntry]
    public var favorites: [FilterHistoryEntry] { entries.filter(\.favorite) }
    public var recent: [FilterHistoryEntry] { entries.filter { !$0.favorite } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([FilterHistoryEntry].self, from: $0) } ?? []
        normalize()
    }
    public func isFavorite(_ filter: SavedLogFilter) -> Bool { entries.contains { $0.filter == filter && $0.favorite } }
    public mutating func remember(_ filter: SavedLogFilter) {
        guard filter.canSave else { return }
        let entry = FilterHistoryEntry(filter: filter, favorite: isFavorite(filter))
        if entries.first == entry { return }
        entries.removeAll { $0.filter == filter }; entries.insert(entry, at: 0)
        normalize(); save()
    }
    public mutating func toggleFavorite(_ filter: SavedLogFilter) {
        guard filter.canSave else { return }
        let entry = FilterHistoryEntry(filter: filter, favorite: !isFavorite(filter))
        entries.removeAll { $0.filter == filter }; entries.insert(entry, at: 0)
        normalize(); save()
    }
    public mutating func clearRecent() { entries.removeAll { !$0.favorite }; save() }
    private mutating func normalize() {
        var seen = Set<SavedLogFilter>(), recentCount = 0
        entries = entries.filter {
            guard $0.filter.canSave, seen.insert($0.filter).inserted else { return false }
            if $0.favorite { return true }
            recentCount += 1; return recentCount <= 30
        }
    }
    private func save() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) } }
}
