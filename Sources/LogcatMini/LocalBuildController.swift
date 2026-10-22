import AppKit
import Combine
import CryptoKit
import Darwin

@MainActor final class LocalBuildController: ObservableObject {
    enum Stage: String { case idle = "尚未运行", preparing = "准备中", building = "编译中", verifying = "核对 APK", installing = "安装中", launching = "启动中", succeeded = "已运行", failed = "失败", cancelled = "已取消" }
    struct Target: Equatable { let adb: String; let serial: String; let name: String }
    typealias Runner = (BuildProcessRunner.Command, @escaping BuildProcessRunner.Output) async throws -> BuildProcessRunner.Result
    @Published private(set) var projects: [LocalBuildProject]
    @Published var draft = LocalBuildProject()
    @Published private(set) var stage = Stage.idle
    @Published private(set) var failedStage: Stage?
    @Published private(set) var busy = false
    @Published private(set) var detecting = false
    @Published private(set) var output = ""
    @Published private(set) var message = ""
    @Published private(set) var branch = ""
    @Published private(set) var activeTarget: Target?
    @Published private(set) var activePackage = ""
    @Published private(set) var installed = false
    @Published var configurationError: String?
    var onInstalled: ((Target, String) async -> Void)?
    var installationAllowed: () -> Bool = { true }
    private let defaults: UserDefaults
    private let run: Runner
    private var task: Task<Void, Never>?
    private var detection: Task<Void, Never>?
    private var detectionID = UUID()
    private var runID = UUID()
    private static let key = "localBuild.projects.v1"

    init(defaults: UserDefaults = .standard, run: Runner? = nil) {
        self.defaults = defaults
        projects = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([LocalBuildProject].self, from: $0) } ?? []
        let runner = BuildProcessRunner()
        self.run = run ?? { try await runner.run($0, output: $1) }
    }
    func project(for package: String) -> LocalBuildProject? { projects.first { $0.packageID == package } }
    func refreshBranch() async {
        let directory = draft.directory
        guard !directory.isEmpty else { branch = ""; return }
        do {
            let result = try await run(.init(executable: "/usr/bin/git", arguments: ["-C", directory, "branch", "--show-current"], timeout: 15), { _ in })
            guard !Task.isCancelled, draft.directory == directory else { return }
            let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            branch = result.status == 0 ? (name.isEmpty ? "detached HEAD" : name) : "非 Git 项目"
        } catch { if !Task.isCancelled, draft.directory == directory { branch = "无法读取分支" } }
    }
    func edit(_ package: String) {
        guard !busy else { return }
        detectionID = UUID(); detection?.cancel(); detecting = false
        let previousDirectory = draft.directory
        draft = project(for: package) ?? LocalBuildProject(packageID: package)
        configurationError = nil
        if draft.directory != previousDirectory { branch = "" }
    }
    @discardableResult func save(_ project: LocalBuildProject) -> Bool {
        guard !busy && !detecting else { return false }
        do {
            try project.validate()
            projects.removeAll { $0.packageID == project.packageID }; projects.append(project)
            projects.sort { $0.packageID < $1.packageID }
            defaults.set(try JSONEncoder().encode(projects), forKey: Self.key)
            draft = project; configurationError = nil; return true
        } catch { configurationError = error.localizedDescription; return false }
    }
    func remove(_ package: String) {
        guard !busy else { return }
        projects.removeAll { $0.packageID == package }
        defaults.set(try? JSONEncoder().encode(projects), forKey: Self.key)
        edit(package)
    }
    func chooseDirectory(_ field: WritableKeyPath<LocalBuildProject, String>) {
        guard !busy && !detecting else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = field == \.directory ? "选择 Android 项目根目录" : field == \.javaHome ? "选择 JDK Home（包含 bin/java）" : "选择 Android SDK 目录"
        if !draft[keyPath: field].isEmpty { panel.directoryURL = URL(fileURLWithPath: draft[keyPath: field]) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft[keyPath: field] = url.path
        if field == \.directory { detectEnvironment() }
    }
    func detectEnvironment() {
        guard !busy && !detecting, !draft.directory.isEmpty else { return }
        detecting = true; configurationError = nil
        let id = UUID(); detectionID = id
        let directory = draft.directory
        detection = Task {
            defer { if detectionID == id { detecting = false } }
            do {
                let root = URL(fileURLWithPath: directory)
                guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent("gradlew").path) else { throw LocalBuildError.message("此目录没有 gradlew，请选择项目根目录。") }
                let properties = LocalBuildProject.properties(at: root.appendingPathComponent("build.properties"))
                let local = LocalBuildProject.properties(at: root.appendingPathComponent("local.properties"))
                let gradle = LocalBuildProject.properties(at: root.appendingPathComponent("gradle.properties"))
                var found = draft
                if found.packageID.isEmpty { found.packageID = properties["applicationId"] ?? "" }
                found.sdkRoot = local["sdk.dir"]?.replacingOccurrences(of: "\\:", with: ":").replacingOccurrences(of: "\\ ", with: " ") ?? NSHomeDirectory() + "/Library/Android/sdk"
                if let configured = gradle["org.gradle.java.home"], FileManager.default.isExecutableFile(atPath: configured + "/bin/java") {
                    found.javaHome = configured
                } else {
                    let java = try await run(.init(executable: "/usr/libexec/java_home", arguments: ["-v", "17"], timeout: 15), { _ in })
                    guard java.status == 0 else { throw LocalBuildError.message("未找到 JDK 17，请手动选择此项目使用的 JDK。") }
                    found.javaHome = java.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let git = try await run(.init(executable: "/usr/bin/git", arguments: ["-C", directory, "branch", "--show-current"], timeout: 15), { _ in })
                try Task.checkCancellation()
                guard detectionID == id, draft.directory == directory else { return }
                draft = found; branch = git.status == 0 ? git.output.trimmingCharacters(in: .whitespacesAndNewlines) : "非 Git 项目"
                try await readVariants(for: found, detectionID: id)
            } catch { if !Task.isCancelled, detectionID == id { configurationError = error.localizedDescription } }
        }
    }
    func refreshVariants() {
        guard !busy && !detecting else { return }
        detecting = true; configurationError = nil
        let id = UUID(); detectionID = id; let project = draft
        detection = Task {
            defer { if detectionID == id { detecting = false } }
            do { try await readVariants(for: project, detectionID: id) }
            catch { if !Task.isCancelled, detectionID == id { configurationError = error.localizedDescription } }
        }
    }
    private func readVariants(for project: LocalBuildProject, detectionID id: UUID) async throws {
        try project.validate(packageRequired: false)
        draft.variantCatalog = nil; draft.variantCatalogScope = nil
        let fd = try Self.lockProject(project.root)
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        let git = try await run(.init(executable: "/usr/bin/git", arguments: ["-C", project.directory, "branch", "--show-current"], timeout: 15), { _ in })
        try Task.checkCancellation()
        guard detectionID == id else { return }
        branch = git.status == 0 ? git.output.trimmingCharacters(in: .whitespacesAndNewlines) : "非 Git 项目"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-variants-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("variants.gradle")
        try LocalBuildVariant.initScript.write(to: script, atomically: true, encoding: .utf8)
        append("\n【读取变体】\(project.directory) · \(project.module)\n")
        let owner = self
        let result = try await run(.init(executable: "/bin/bash",
            arguments: project.arguments(for: ":" + project.module + ":" + LocalBuildVariant.taskName) + ["--init-script", script.path, "--no-configuration-cache"],
            directory: project.root, environment: ["JAVA_HOME": project.javaHome, "ANDROID_HOME": project.sdkRoot, "ANDROID_SDK_ROOT": project.sdkRoot], timeout: 180), { text in
                Task { @MainActor in if owner.detectionID == id { owner.append(text) } }
            })
        try Task.checkCancellation()
        guard result.status == 0 else { throw LocalBuildError.message("读取 Flavor 失败，请查看构建输出。\n" + String(result.output.suffix(1000))) }
        let variants = try LocalBuildVariant.parse(result.output)
        guard detectionID == id, draft.catalogScope == project.catalogScope else { return }
        draft.variantCatalog = variants; draft.variantCatalogScope = project.catalogScope
        // Prefer the currently bound App; switching to a different flavor is an explicit selection.
        let matching = variants.filter { $0.applicationId == draft.packageID }
        if let selected = matching.first(where: { $0.name == draft.variant }) ?? matching.first(where: { $0.buildType == "debug" }) ?? matching.first {
            selectVariant(selected.name)
        } else if draft.packageID.isEmpty, let first = variants.first(where: { $0.buildType == "debug" }) ?? variants.first {
            selectVariant(first.name)
        }
        append("已读取 \(variants.count) 个构建变体。\n")
    }
    func selectVariant(_ name: String) {
        guard let selected = draft.availableVariants.first(where: { $0.name == name }) else { return }
        draft.variant = selected.name; draft.packageID = selected.applicationId; configurationError = nil
    }
    func selectFlavor(_ key: String) {
        let options = draft.availableVariants.filter { $0.flavorKey == key }
        let buildType = draft.selectedVariant?.buildType ?? "debug"
        if let selected = options.first(where: { $0.buildType == buildType }) ?? options.first { selectVariant(selected.name) }
    }
    func cancelDetection() { detection?.cancel() }
    func waitForDetection() async { await detection?.value }
    func append(_ text: String) {
        output += text
        if output.count > 240_000 { output = "[较早的构建输出已省略]\n" + output.suffix(180_000) }
    }
    private func transition(_ next: Stage, _ text: String) { stage = next; message = text; append("\n【\(next.rawValue)】\(text)\n") }

    @discardableResult func start(_ project: LocalBuildProject, target: Target) -> Bool {
        guard !busy && !detecting else { return false }
        guard installationAllowed() else { configurationError = "其他 APK 正在安装，请等待结束后再编译运行。"; return false }
        do { try project.validate() } catch { configurationError = error.localizedDescription; return false }
        guard !target.serial.isEmpty, FileManager.default.isExecutableFile(atPath: target.adb) else { configurationError = "请选择已连接手机并配置 ADB。"; return false }
        busy = true; installed = false; failedStage = nil; configurationError = nil; output = ""; activeTarget = target; activePackage = project.packageID
        let id = UUID(); runID = id
        transition(.preparing, "\(project.packageID) → \(target.name) · \(target.serial)")
        task = Task {
            var lockFD: Int32 = -1
            var snapshot: URL?
            defer {
                if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
                if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
                busy = false
            }
            do {
                lockFD = try Self.lockProject(project.root)
                let owner = self
                let commandOutput: BuildProcessRunner.Output = { text in
                    Task { @MainActor in guard owner.runID == id else { return }; owner.append(text) }
                }
                func execute(_ command: BuildProcessRunner.Command) async throws -> String {
                    try Task.checkCancellation()
                    let result = try await self.run(command, commandOutput)
                    try Task.checkCancellation()
                    guard result.status == 0 else { throw LocalBuildError.message("命令退出码 \(result.status)\n" + String(result.output.suffix(1600))) }
                    return result.output
                }
                let device = try await execute(.init(executable: target.adb, arguments: ["-s", target.serial, "get-state"], timeout: 15))
                guard device.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else { throw LocalBuildError.message("目标手机未就绪。") }
                let git = try await run(.init(executable: "/usr/bin/git", arguments: ["-C", project.directory, "branch", "--show-current"], timeout: 15), { _ in })
                branch = git.status == 0 ? git.output.trimmingCharacters(in: .whitespacesAndNewlines) : "非 Git 项目"
                append("项目：\(project.directory)\n分支：\(branch.isEmpty ? "detached HEAD" : branch)\n任务：\(project.task)\nJDK：\(project.javaHome)\n使用当前目录已保存的代码。\n")
                transition(.building, project.lowMemory ? "节省内存：Gradle 堆上限 3 GB，最多 2 个 worker" : "使用项目默认内存配置")
                _ = try await execute(.init(executable: "/bin/bash", arguments: project.buildArguments, directory: project.root,
                                            environment: ["JAVA_HOME": project.javaHome, "ANDROID_HOME": project.sdkRoot, "ANDROID_SDK_ROOT": project.sdkRoot], timeout: 1800))
                transition(.verifying, "读取本次变体输出并核对 APK 包名")
                let artifact = try project.artifact()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-build-" + id.uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); snapshot = folder
                let apk = folder.appendingPathComponent(artifact.lastPathComponent)
                try FileManager.default.copyItem(at: artifact, to: apk)
                let badging = try await execute(.init(executable: project.aapt(), arguments: ["dump", "badging", apk.path], timeout: 30))
                guard badging.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("package: name='\(project.packageID)' ") }) else {
                    throw LocalBuildError.message("APK 实际包名与关联应用不符，已停止安装。")
                }
                append("APK：\(artifact.path)\n")
                transition(.installing, "覆盖安装到 \(target.name) · \(target.serial)，保留应用数据")
                let install = try await execute(.init(executable: target.adb, arguments: ["-s", target.serial, "install", "-r", apk.path], timeout: 240))
                guard install.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Success" }) else {
                    throw LocalBuildError.message("手机未返回安装成功；未卸载原应用。\n" + String(install.suffix(1200)))
                }
                installed = true
                await onInstalled?(target, project.packageID)
                try Task.checkCancellation()
                transition(.launching, "安装成功，正在启动并检查应用进程")
                let resolved = try await execute(.init(executable: target.adb, arguments: ["-s", target.serial, "shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", project.packageID], timeout: 20))
                guard let component = resolved.split(whereSeparator: \.isNewline).map(String.init).first(where: {
                    $0.hasPrefix(project.packageID + "/") && $0.range(of: #"^[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+$"#, options: .regularExpression) != nil
                }) else { throw LocalBuildError.message("安装成功，但未找到应用的桌面启动入口。") }
                let launched = try await execute(.init(executable: target.adb, arguments: ["-s", target.serial, "shell", "am", "start", "-W", "-S", "-n", component], timeout: 60))
                guard launched.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Status: ok" }), !launched.contains("Error:") else {
                    throw LocalBuildError.message("安装成功，但启动未成功。\n" + String(launched.suffix(1200)))
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let pid = try await execute(.init(executable: target.adb, arguments: ["-s", target.serial, "shell", "pidof", project.packageID], timeout: 15))
                guard pid.split(whereSeparator: \.isWhitespace).contains(where: { Int($0) != nil }) else { throw LocalBuildError.message("启动后未检测到应用进程，请查看手机崩溃日志。") }
                transition(.succeeded, "\(target.name) · \(project.packageID) · PID \(pid.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch is CancellationError { transition(.cancelled, installed ? "已停止后续操作；APK 已安装，应用数据保留。" : "任务已取消。若已进入安装阶段，请刷新设备应用列表确认结果。") }
            catch { failedStage = stage; transition(.failed, (installed ? "APK 已安装。" : "") + error.localizedDescription) }
        }
        return true
    }
    func cancel() { guard busy else { return }; message = "正在取消…"; task?.cancel() }
    func waitUntilFinished() async { await task?.value }
    func finishBeforeQuit() async { detection?.cancel(); cancel(); await detection?.value; await task?.value }
    func exportOutput() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "build-output.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8) } catch { configurationError = error.localizedDescription }
    }
    private static func lockProject(_ root: URL) throws -> Int32 {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Logcat Mini/BuildLocks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(root.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
        let fd = Darwin.open(folder.appendingPathComponent(hash).path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LocalBuildError.message("无法创建项目构建锁。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw LocalBuildError.message("此项目已在另一个 Logcat Mini 窗口中构建，请等待结束。") }
        return fd
    }
}
