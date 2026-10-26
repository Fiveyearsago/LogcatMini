import Foundation

/// Local display cache, keyed by the selected ADB device. Never treated as a fresh device read.
@MainActor final class AdvertisingIDCache {
    struct Entry: Codable, Equatable {
        let result: AdvertisingIDResult
        let readAt: Date
        var needsRefresh: Bool
    }

    static let shared = AdvertisingIDCache()
    private let defaults: UserDefaults
    private let key = "deviceInfo.advertisingIDCache.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func entry(for serial: String) -> Entry? {
        guard let entry = entries[serial], entry.result.isCacheable else { return nil }
        return entry
    }

    @discardableResult func store(_ result: AdvertisingIDResult, for serial: String, at date: Date = Date()) -> Entry? {
        guard !serial.isEmpty, result.isCacheable else { return nil }
        var values = entries
        let entry = Entry(result: result, readAt: date, needsRefresh: false)
        values[serial] = entry
        write(values)
        return entry
    }

    func markNeedsRefresh(for serial: String) {
        var values = entries
        guard var entry = values[serial] else { return }
        entry.needsRefresh = true; values[serial] = entry
        write(values)
    }

    private var entries: [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return values
    }
    private func write(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
