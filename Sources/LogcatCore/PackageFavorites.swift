import Foundation

/// Favorites use package names, so they remain useful across devices and app launches.
public struct PackageFavorites {
    private let defaults: UserDefaults
    private static let key = "favoritePackages"
    public private(set) var packageIDs: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        packageIDs = Array(Set((defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.isEmpty })).sorted()
    }

    public func contains(_ packageID: String) -> Bool { packageIDs.contains(packageID) }

    public mutating func toggle(_ packageID: String) {
        guard !packageID.isEmpty else { return }
        if let index = packageIDs.firstIndex(of: packageID) { packageIDs.remove(at: index) }
        else { packageIDs.append(packageID); packageIDs.sort() }
        defaults.set(packageIDs, forKey: Self.key)
    }
}
