import AppKit
import Combine

enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case screenshot, recording
    var id: String { rawValue }
    var title: String { self == .screenshot ? "截图" : "录屏" }
    var symbol: String { self == .screenshot ? "photo" : "video" }
    var fileExtension: String { self == .screenshot ? "png" : "mp4" }
}

struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: CaptureKind
    let url: URL
    let createdAt: Date
    let deviceName: String
    let serial: String
    let duration: Int?
    var filename: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Only the catalog is stored here. Captured files stay in the folders chosen by the user.
@MainActor final class MediaLibrary: ObservableObject {
    private struct Catalog: Codable {
        var screenshotDirectory: URL?
        var recordingDirectory: URL?
        var folders: [URL] = []
        var records: [CaptureRecord] = []
    }
    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var screenshotDirectory: URL?
    @Published private(set) var recordingDirectory: URL?
    @Published private(set) var refreshing = false
    @Published private(set) var refreshGeneration = 0
    @Published var error: String?
    private var folders: [URL] = []
    private let catalogURL: URL

    init(catalogURL: URL? = nil) {
        self.catalogURL = catalogURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.songran.LogcatMini")
            .appendingPathComponent("media-history.json")
        do {
            if FileManager.default.fileExists(atPath: self.catalogURL.path) {
                let saved = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: self.catalogURL))
                screenshotDirectory = saved.screenshotDirectory; recordingDirectory = saved.recordingDirectory
                folders = saved.folders; records = saved.records.sorted { $0.createdAt > $1.createdAt }
            }
        } catch { self.error = "无法读取截图与录屏历史：\(error.localizedDescription)" }
    }
    func directory(for kind: CaptureKind) -> URL? {
        kind == .screenshot ? screenshotDirectory : recordingDirectory
    }
    func setDirectory(_ url: URL, for kind: CaptureKind, shareIfUnset: Bool = false) throws {
        let url = url.standardizedFileURL
        try validateDirectory(url)
        if kind == .screenshot { screenshotDirectory = url } else { recordingDirectory = url }
        if shareIfUnset {
            if screenshotDirectory == nil { screenshotDirectory = url }
            if recordingDirectory == nil { recordingDirectory = url }
        }
        if !folders.contains(url) { folders.append(url) }
        persist()
    }
    @discardableResult func chooseDirectory(for kind: CaptureKind, shareIfUnset: Bool = false) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.title = "选择\(kind.title)保存文件夹"; panel.prompt = "使用此文件夹"
        panel.message = "之后自动保存到此文件夹，可随时在设置中更换。"
        panel.directoryURL = directory(for: kind) ?? screenshotDirectory ?? recordingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try setDirectory(url, for: kind, shareIfUnset: shareIfUnset)
            Task { await refresh() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func destination(for kind: CaptureKind, serial: String, now: Date = Date()) throws -> URL? {
        if directory(for: kind) == nil, !chooseDirectory(for: kind, shareIfUnset: true) { return nil }
        guard let directory = directory(for: kind) else { return nil }
        try validateDirectory(directory)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let safe = serial.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        // A random suffix also avoids overwriting files during rapid captures or after clock changes.
        return directory.appendingPathComponent("\(kind.title)-\(safe)-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8)).\(kind.fileExtension)")
    }
    func add(kind: CaptureKind, url: URL, deviceName: String, serial: String, createdAt: Date, duration: Int? = nil) {
        let url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        records.removeAll { $0.url == url }
        records.append(CaptureRecord(id: UUID(), kind: kind, url: url, createdAt: createdAt, deviceName: deviceName, serial: serial, duration: duration))
        records.sort { $0.createdAt > $1.createdAt }
        let parent = url.deletingLastPathComponent()
        if !folders.contains(parent) { folders.append(parent) }
        persist()
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let directories = folders
        let discovered = await Task.detached(priority: .utility) {
            var result: [CaptureRecord] = []
            for directory in directories {
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for url in files {
                    // Import older Logcat Mini captures, not unrelated personal media in the folder.
                    guard let kind = CaptureKind.allCases.first(where: {
                        url.lastPathComponent.hasPrefix($0.title + "-") && url.pathExtension.lowercased() == $0.fileExtension
                    }), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]), values.isRegularFile == true else { continue }
                    result.append(CaptureRecord(id: UUID(), kind: kind, url: url.standardizedFileURL,
                        createdAt: values.creationDate ?? .distantPast, deviceName: "已有文件", serial: "", duration: nil))
                }
            }
            return result
        }.value
        var known = Set(records.map(\.url))
        let additions = discovered.filter { known.insert($0.url).inserted }
        if !additions.isEmpty { records += additions; records.sort { $0.createdAt > $1.createdAt }; persist() }
        // Publish even without additions to update missing-file labels when history is refreshed.
        refreshGeneration &+= 1
        refreshing = false
    }
    func open(_ record: CaptureRecord) {
        guard record.exists else { error = "文件已移动或删除：\(record.url.path)"; return }
        if !NSWorkspace.shared.open(record.url) { error = "无法打开文件：\(record.filename)" }
    }
    func reveal(_ record: CaptureRecord) {
        guard record.exists else { error = "文件已移动或删除：\(record.url.path)"; return }
        NSWorkspace.shared.activateFileViewerSelecting([record.url])
    }
    private func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isWritableFile(atPath: url.path) else {
            throw NSError(domain: "MediaLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "保存文件夹不可用，请在设置中更换：\(url.path)"])
        }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let value = Catalog(screenshotDirectory: screenshotDirectory, recordingDirectory: recordingDirectory, folders: folders, records: records)
            try JSONEncoder().encode(value).write(to: catalogURL, options: .atomic)
        } catch { self.error = "文件已保留，但保存历史或设置失败：\(error.localizedDescription)" }
    }
}
