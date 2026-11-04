import AppKit
import Combine
import CryptoKit
import Darwin
import LogcatCore

struct IOSBuildProject: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case flutter = "Flutter", xcode = "Xcode" }
    var bundleID = ""
    var directory = ""
    var kind = Kind.flutter
    var flutterPath = ""
    var flavor = ""
    var entrypoint = "lib/main.dart"
    var mode = "debug"
    var defines = ""
    var container = ""
    var scheme = "Runner"
    var configuration = "Debug"
    var id: String { bundleID }
    var root: URL { URL(fileURLWithPath: directory).standardizedFileURL }
    static var toolEnvironment: [String: String] {
        // GUI launches do not load shell profiles. Prefer system Git over stale Intel tools,
        // and include Homebrew so Flutter can find CocoaPods without changing the user's shell.
        let standard = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return ["PATH": (standard + inherited.filter { !standard.contains($0) }).joined(separator: ":")]
    }
    var buildLabel: String { kind == .flutter ? [flavor, mode].filter { !$0.isEmpty }.joined(separator: " · ") : "\(scheme) · \(configuration)" }
    func validate() throws {
        guard !bundleID.isEmpty, bundleID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil,
              !directory.isEmpty, FileManager.default.fileExists(atPath: root.path) else { throw LocalBuildError.message("请选择项目目录并填写正确的 Bundle ID。") }
        if kind == .flutter {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("pubspec.yaml").path),
                  FileManager.default.isExecutableFile(atPath: flutterPath), ["debug", "profile", "release"].contains(mode), !entrypoint.isEmpty else {
                throw LocalBuildError.message("Flutter 项目需要 pubspec.yaml、可执行的 Flutter SDK、入口文件和有效构建模式。")
            }
        } else {
            guard ["xcworkspace", "xcodeproj"].contains(URL(fileURLWithPath: container).pathExtension),
                  FileManager.default.fileExists(atPath: container), !scheme.isEmpty, !configuration.isEmpty else {
                throw LocalBuildError.message("请选择 .xcworkspace / .xcodeproj 并填写 Scheme、Configuration。")
            }
        }
    }
    func flutterArguments(device: IOSDevice) throws -> [String] {
        guard device.kind != .simulator || mode == "debug" else { throw LocalBuildError.message("Flutter iOS 模拟器请使用 debug 模式；profile / release 请连接真机。") }
        var args = ["build", "ios", "--" + mode, "--target", entrypoint]
        if device.kind == .simulator { args += ["--simulator"] }
        if !flavor.isEmpty { args += ["--flavor", flavor] }
        for line in defines.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.contains("=") else { throw LocalBuildError.message("Dart Defines 每行应为 KEY=VALUE。") }
            args += ["--dart-define", value]
        }
        return args
    }
    func xcodeArguments(device: IOSDevice, derivedData: URL) -> [String] {
        ["xcodebuild", URL(fileURLWithPath: container).pathExtension == "xcworkspace" ? "-workspace" : "-project", container,
         "-scheme", scheme, "-configuration", configuration, "-destination", "id=" + device.udid, "-derivedDataPath", derivedData.path]
    }
    static func verifyApp(_ url: URL, bundleID: String, device: IOSDevice) throws {
        guard url.pathExtension == "app", let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let executable = info["CFBundleExecutable"] as? String, !executable.contains("/"), !executable.isEmpty,
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent(executable).path) else {
            throw LocalBuildError.message("产物缺失或实际 Bundle ID 不匹配，已停止安装。")
        }
        let expected = device.kind == .simulator ? "iPhoneSimulator" : "iPhoneOS"
        guard (info["CFBundleSupportedPlatforms"] as? [String])?.contains(expected) == true else {
            throw LocalBuildError.message(".app 的目标平台与所选设备不匹配，已停止安装。")
        }
    }
    static func xcodeProduct(_ text: String, bundleID: String) throws -> URL {
        // xcodebuild can prepend timestamped [MT] diagnostics even with -json.
        let starts = try NSRegularExpression(pattern: #"(?m)^\s*\["#).matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in starts {
            guard let range = Range(match.range, in: text), let end = text.lastIndex(of: "]"), range.lowerBound < end,
                  let values = try? JSONSerialization.jsonObject(with: Data(text[range.lowerBound...end].utf8)) as? [[String: Any]] else { continue }
            let matches = values.compactMap { $0["buildSettings"] as? [String: Any] }.filter { $0["PRODUCT_BUNDLE_IDENTIFIER"] as? String == bundleID && $0["WRAPPER_EXTENSION"] as? String == "app" }
            guard matches.count == 1, let directory = matches[0]["TARGET_BUILD_DIR"] as? String, let name = matches[0]["FULL_PRODUCT_NAME"] as? String else { throw LocalBuildError.message("Scheme 未生成唯一匹配的 iOS App。") }
            return URL(fileURLWithPath: directory).appendingPathComponent(name)
        }
        throw LocalBuildError.message("无法解析 Xcode 构建产物路径。")
    }
}

@MainActor final class IOSBuildController: ObservableObject {
    typealias Runner = LocalBuildController.Runner
    @Published private(set) var projects: [IOSBuildProject]
    @Published var draft = IOSBuildProject()
    @Published private(set) var busy = false
    @Published private(set) var output = ""
    @Published private(set) var status = "尚未运行"
    @Published private(set) var branch = ""
    @Published private(set) var target: IOSDevice?
    @Published var error: String?
    var onInstalled: ((IOSDevice, String) async -> Void)?
    private let defaults: UserDefaults
    private let run: Runner
    private var task: Task<Void, Never>?
    private static let key = "ios.build.projects.v1"
    init(defaults: UserDefaults = .standard, run: Runner? = nil) {
        self.defaults = defaults
        projects = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([IOSBuildProject].self, from: $0) } ?? []
        let runner = BuildProcessRunner(); self.run = run ?? { try await runner.run($0, output: $1) }
    }
    func project(for id: String) -> IOSBuildProject? { projects.first { $0.bundleID == id } }
    func edit(_ id: String) { guard !busy else { return }; draft = project(for: id) ?? IOSBuildProject(bundleID: id); error = nil; branch = "" }
    @discardableResult func save() -> Bool {
        do {
            try draft.validate(); projects.removeAll { $0.bundleID == draft.bundleID }; projects.append(draft)
            defaults.set(try JSONEncoder().encode(projects), forKey: Self.key); error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func chooseDirectory() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = "选择 Flutter 或 iOS 项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configureDirectory(url)
    }
    func configureDirectory(_ url: URL) {
        var root = url
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("pubspec.yaml").path), FileManager.default.fileExists(atPath: root.appendingPathComponent("flutter/pubspec.yaml").path) { root.appendPathComponent("flutter") }
        draft.directory = root.path
        draft.kind = FileManager.default.fileExists(atPath: root.appendingPathComponent("pubspec.yaml").path) ? .flutter : .xcode
        let config = (try? String(contentsOf: root.appendingPathComponent("ios/Flutter/Generated.xcconfig"))) ?? ""
        let sdk = config.split(whereSeparator: \.isNewline).first { $0.hasPrefix("FLUTTER_ROOT=") }.map { String($0.dropFirst("FLUTTER_ROOT=".count)) + "/bin/flutter" }
        draft.flutterPath = sdk ?? IOSTools.locate("flutter") ?? ""
        let folder = draft.kind == .flutter ? root.appendingPathComponent("ios") : root
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        draft.container = (files.first { $0.pathExtension == "xcworkspace" } ?? files.first { $0.pathExtension == "xcodeproj" })?.path ?? ""
        Task { await refreshBranch() }
    }
    func refreshBranch() async {
        let directory = draft.directory
        guard !directory.isEmpty else { return }
        let result = try? await run(.init(executable: "/usr/bin/git", arguments: ["-C", directory, "branch", "--show-current"], timeout: 10), { _ in })
        guard draft.directory == directory else { return }
        branch = result?.status == 0 ? result!.output.trimmingCharacters(in: .whitespacesAndNewlines) : "非 Git 项目"
    }
    func append(_ text: String) { output += text; if output.count > 240_000 { output = "[较早的输出已省略]\n" + output.suffix(180_000) } }
    private func execute(_ command: BuildProcessRunner.Command) async throws -> String {
        try Task.checkCancellation()
        var command = command
        command.environment = IOSBuildProject.toolEnvironment.merging(command.environment) { _, value in value }
        let result = try await run(command) { [weak self] text in Task { @MainActor in self?.append(text) } }
        try Task.checkCancellation()
        guard result.status == 0 else { throw LocalBuildError.message(String(result.output.suffix(1800))) }
        return result.output
    }
    @discardableResult func start(_ project: IOSBuildProject, device: IOSDevice) -> Bool {
        guard !busy else { return false }
        do { try project.validate(); if project.kind == .flutter { _ = try project.flutterArguments(device: device) } }
        catch { self.error = error.localizedDescription; return false }
        if draft.directory != project.directory { branch = "" }
        draft = project
        busy = true; target = device; error = nil; output = "项目：\(project.directory)\n目标：\(device.title) · \(device.udid)\n\(project.buildLabel)\n"; status = "编译中"
        task = Task {
            var installed = false
            defer { busy = false }
            do {
                let fd = try LocalBuildController.lockProject(project.root)
                defer { flock(fd, LOCK_UN); Darwin.close(fd) }
                let artifact: URL
                if project.kind == .flutter {
                    _ = try await execute(.init(executable: project.flutterPath, arguments: try project.flutterArguments(device: device), directory: project.root, timeout: 1800))
                    let folder = project.root.appendingPathComponent(device.kind == .simulator ? "build/ios/iphonesimulator" : "build/ios/iphoneos")
                    let apps = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
                    let matches = apps.filter { (try? IOSBuildProject.verifyApp($0, bundleID: project.bundleID, device: device)) != nil }
                    guard matches.count == 1 else { throw LocalBuildError.message("未找到唯一匹配 Bundle ID 和平台的 Flutter .app，已停止安装。") }
                    artifact = matches[0]
                } else {
                    let hash = SHA256.hash(data: Data(project.root.path.utf8)).map { String(format: "%02x", $0) }.joined()
                    let derived = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Logcat Mini/iOSBuilds/" + hash)
                    let args = project.xcodeArguments(device: device, derivedData: derived)
                    _ = try await execute(.init(executable: "/usr/bin/xcrun", arguments: args + ["build"], directory: project.root, timeout: 1800))
                    let text = try await execute(.init(executable: "/usr/bin/xcrun", arguments: args + ["-showBuildSettings", "-json"], directory: project.root, timeout: 60))
                    artifact = try IOSBuildProject.xcodeProduct(text, bundleID: project.bundleID)
                }
                try Task.checkCancellation(); status = "核对产物"
                try IOSBuildProject.verifyApp(artifact, bundleID: project.bundleID, device: device)
                try await installArtifact(artifact, bundleID: project.bundleID, device: device) { installed = true }
                status = "已运行"; append("\n已运行：\(device.title) · \(project.bundleID)\n")
            } catch is CancellationError { status = "已取消"; append(installed ? "\n应用已安装，后续操作已取消。\n" : "\n已取消。若取消发生在安装阶段，请刷新应用列表确认。\n") }
            catch { self.error = "\(status)失败：\(error.localizedDescription)"; status = "失败"; append("\n\(self.error!)\n") }
        }
        return true
    }
    /// Install an explicitly selected .app with the same target and bundle validation as builds.
    func chooseApp(device: IOSDevice) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择与当前设备平台匹配的 iOS .app"; panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = installExisting(url, device: device)
    }
    @discardableResult func installExisting(_ artifact: URL, device: IOSDevice) -> Bool {
        guard !busy else { return false }
        do {
            let data = try Data(contentsOf: artifact.appendingPathComponent("Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { throw LocalBuildError.message("无法读取 .app 的 Bundle ID。") }
            try IOSBuildProject.verifyApp(artifact, bundleID: id, device: device)
            busy = true; target = device; error = nil; status = "核对产物"; output = "安装：\(artifact.path)\n目标：\(device.title) · \(device.udid)\n"
            task = Task {
                defer { busy = false }
                do { try await installArtifact(artifact, bundleID: id, device: device); status = "已运行"; append("\n已运行：\(id)\n") }
                catch is CancellationError { status = "已取消"; append("\n操作已取消，请刷新应用列表确认安装状态。\n") }
                catch { self.error = error.localizedDescription; status = "失败"; append("\n\(self.error!)\n") }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func installArtifact(_ artifact: URL, bundleID: String, device: IOSDevice, installed: () -> Void = {}) async throws {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-ios-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent(artifact.lastPathComponent)
        try FileManager.default.copyItem(at: artifact, to: app)
        try IOSBuildProject.verifyApp(app, bundleID: bundleID, device: device)
        status = "安装中"
        let install = device.kind == .simulator ? ["simctl", "install", device.udid, app.path] : ["devicectl", "device", "install", "app", "--device", device.udid, app.path]
        _ = try await execute(.init(executable: "/usr/bin/xcrun", arguments: install, timeout: 180)); installed()
        await onInstalled?(device, bundleID)
        status = "启动中"
        let launch = device.kind == .simulator ? ["simctl", "launch", "--terminate-running-process", device.udid, bundleID] : ["devicectl", "device", "process", "launch", "--terminate-existing", "--device", device.udid, bundleID]
        _ = try await execute(.init(executable: "/usr/bin/xcrun", arguments: launch, timeout: 60))
    }
    func cancel() { task?.cancel() }
    func waitUntilFinished() async { await task?.value }
    func finishBeforeQuit() async { cancel(); await task?.value }
    func exportOutput() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ios-build-output.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}
