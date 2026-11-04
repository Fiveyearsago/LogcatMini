import AppKit
import AVFoundation
import Combine
import LogcatCore

/// SIGINT is required by simctl/devicectl to finalize the movie before it is copied to the library.
final class IOSScreenRecording: @unchecked Sendable {
    let file: URL
    private let child = Process(), pipe = Pipe()
    private var deadline: DispatchWorkItem?
    init(device: IOSDevice) throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-ios-record-\(UUID().uuidString).mp4")
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = IOSTools.recordingArguments(device: device, destination: file.path)
        child.standardOutput = pipe; child.standardError = pipe; child.standardInput = FileHandle.nullDevice
        try child.run()
        let deadline = DispatchWorkItem { [weak self] in self?.stop() }
        self.deadline = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: deadline)
    }
    func stop() {
        guard child.isRunning else { return }
        child.interrupt()
        let child = child
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
    }
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                child.waitUntilExit(); deadline?.cancel()
                if child.terminationStatus == 0 || child.terminationStatus == SIGINT {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LocalBuildError.message("录屏未正常完成：\(output.suffix(1800))\n临时文件：\(file.path)"))
                }
            }
        }
    }
}

@MainActor final class IOSMediaController: ObservableObject {
    var library: MediaLibrary
    @Published private(set) var takingScreenshot = false
    @Published private(set) var recording = false
    @Published private(set) var saving = false
    @Published private(set) var canRetry = false
    @Published private(set) var elapsed = 0
    @Published private(set) var recordingDevice = ""
    @Published private(set) var lastSaved: URL?
    @Published var error: String?
    @Published var notice: String?
    private var session: IOSScreenRecording?
    private var task: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?
    private var timer: Timer?
    private var target: IOSDevice?
    private var started = Date()
    var busy: Bool { recording || saving || canRetry }
    var elapsedText: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }
    init(library: MediaLibrary? = nil) { self.library = library ?? MediaLibrary() }
    func screenshot(_ device: IOSDevice, copyOnly: Bool = false) {
        guard !takingScreenshot else { return }
        do {
            let destination = copyOnly ? nil : try library.destination(for: .screenshot, serial: device.id)
            if !copyOnly && destination == nil { return }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-ios-shot-\(UUID().uuidString).png")
            takingScreenshot = true; error = nil; notice = nil
            screenshotTask = Task {
                defer { takingScreenshot = false; try? FileManager.default.removeItem(at: temporary) }
                do {
                    try await IOSDeviceService.screenshot(device, to: temporary)
                    if let destination {
                        try FileManager.default.copyItem(at: temporary, to: destination)
                        lastSaved = destination
                        library.add(kind: .screenshot, url: destination, deviceName: device.title, serial: device.id, createdAt: Date())
                    }
                    try ScreenshotClipboard.copyFile(temporary)
                    notice = copyOnly ? "截图已复制。" : "截图已保存并复制。"
                } catch { self.error = "\(device.name) 截图失败：\(error.localizedDescription)" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func startRecording(_ device: IOSDevice) {
        guard !busy else { return }
        do {
            guard let destination = try library.destination(for: .recording, serial: device.id) else { return }
            let session = try IOSScreenRecording(device: device)
            self.session = session; target = device; recordingDevice = device.title
            recording = true; saving = false; error = nil; notice = nil; elapsed = 0; started = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }; elapsed = Int(Date().timeIntervalSince(started))
                }
            }
            task = Task {
                do {
                    try await session.wait(); recording = false; saving = true
                    try await save(session, to: destination, device: device)
                } catch { self.error = error.localizedDescription; canRetry = FileManager.default.fileExists(atPath: session.file.path) }
                timer?.invalidate(); timer = nil; recording = false; saving = false
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ session: IOSScreenRecording, to destination: URL, device: IOSDevice) async throws {
        let asset = AVURLAsset(url: session.file)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw LocalBuildError.message("录屏文件没有可播放的视频，已保留临时文件：\(session.file.path)")
        }
        do { try FileManager.default.copyItem(at: session.file, to: destination) }
        catch { throw LocalBuildError.message("录屏保存失败，可重试。临时文件：\(session.file.path)\n\(error.localizedDescription)") }
        library.add(kind: .recording, url: destination, deviceName: device.title, serial: device.id, createdAt: started, duration: Int(duration.seconds))
        lastSaved = destination; canRetry = false; self.session = nil
        try? FileManager.default.removeItem(at: session.file)
        notice = "录屏已保存。"
    }
    func stopRecording() {
        guard recording && !saving else { return }; saving = true; session?.stop()
    }
    func retrySave() {
        guard let session, let target, canRetry && !saving else { return }
        do {
            guard let destination = try library.destination(for: .recording, serial: target.id) else { return }
            saving = true; error = nil
            task = Task {
                defer { saving = false }
                do { try await save(session, to: destination, device: target) } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func dismissRetry() { guard !recording && !saving else { return }; session = nil; canRetry = false }
    func revealSaved() { if let lastSaved { NSWorkspace.shared.activateFileViewerSelecting([lastSaved]) } }
    func finishBeforeQuit() async -> Bool {
        await screenshotTask?.value
        if recording { stopRecording() }
        await task?.value
        return !canRetry
    }
}

@MainActor final class IOSPreviewController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var target: IOSDevice?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var controllable = false
    @Published private(set) var liveFrames = false
    @Published private(set) var controlError: String?
    @Published private(set) var hostAppName = "模拟器窗口"
    private var simulator: IOSSimulatorSession?
    private var lastFrame = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func connect(_ device: IOSDevice) {
        stop(); target = device; loading = true
        let id = UUID(); generation = id
        task = Task { [self] in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-ios-preview-\(id).png")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                if device.kind == .simulator {
                    do {
                        let developer = try await Self.developerDirectory()
                        guard !Task.isCancelled, generation == id else { return }
                        hostAppName = Self.hostApp(developer: developer)?.deletingPathExtension().lastPathComponent == "DeviceHub" ? "Device Hub" : "Simulator"
                        let session = try IOSSimulatorSession(developer: developer.path, udid: device.udid)
                        session.receive = { [weak self] event in
                            Task { @MainActor [weak self] in
                                guard let self, generation == id else { return }
                                switch event["event"] as? String {
                                case "ready": controllable = true; controlError = nil
                                case "frame":
                                    if let encoded = (event["png"] ?? event["jpeg"]) as? String, let data = Data(base64Encoded: encoded), let next = NSImage(data: data) {
                                        image = next; loading = false; liveFrames = true; lastFrame = Date()
                                    }
                                case "error", "closed":
                                    controllable = false; liveFrames = false
                                    if controlError == nil { controlError = event["message"] as? String }
                                    simulator?.stop(); simulator = nil
                                default: break
                                }
                            }
                        }
                        simulator = session; try session.start()
                    } catch { controlError = error.localizedDescription }
                }
                while !Task.isCancelled {
                    if liveFrames, Date().timeIntervalSince(lastFrame) > 3 { liveFrames = false }
                    if liveFrames && image != nil {
                        try await Task.sleep(nanoseconds: 250_000_000); continue
                    }
                    try? FileManager.default.removeItem(at: file)
                    try await IOSDeviceService.screenshot(device, to: file)
                    guard !Task.isCancelled, generation == id else { return }
                    if !liveFrames { image = NSImage(contentsOf: file) }; loading = false
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                self.error = error.localizedDescription; loading = false; image = nil
            }
        }
    }
    func touch(phase: Int, at point: CGPoint) {
        guard controllable else { return }
        simulator?.send(["type": "touch", "phase": phase, "x": point.x, "y": point.y])
    }
    func key(_ usage: Int, modifiers: [Int] = []) {
        guard controllable else { return }
        for code in modifiers { simulator?.send(["type": "key", "usage": code, "down": true]) }
        simulator?.send(["type": "key", "usage": usage, "down": true]); simulator?.send(["type": "key", "usage": usage, "down": false])
        for code in modifiers.reversed() { simulator?.send(["type": "key", "usage": code, "down": false]) }
    }
    @discardableResult func sendText(_ text: String) -> Bool {
        guard controllable, !text.isEmpty else { return false }
        guard text.utf16.count <= 4096 else { controlError = "一次最多发送 4096 个字符，请分段输入。"; return false }
        controlError = nil; simulator?.send(["type": "text", "text": text]); return true
    }
    func releaseInput() { simulator?.send(["type": "release"]) }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; simulator?.stop(); simulator = nil
        image = nil; target = nil; error = nil; loading = false; controllable = false; liveFrames = false; controlError = nil
    }
    static func developerDirectory() async throws -> URL {
        let path = try await IOSDeviceService.xcrun(["--find", "simctl"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func hostApp(developer: URL, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL? {
        // Xcode 27 moved Simulator into Device Hub, next to Xcode's other applications.
        [developer.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app"),
         developer.appendingPathComponent("Applications/Simulator.app")].first { exists($0.path) }
    }
    func openSimulator() {
        guard let target, target.kind == .simulator else { return }
        Task {
            do {
                let developer = try await Self.developerDirectory()
                guard let simulator = Self.hostApp(developer: developer) else {
                    throw LocalBuildError.message("所选 Xcode 中未找到 Device Hub 或 Simulator。请检查 xcode-select 的 Xcode 路径。")
                }
                let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = ["-CurrentDeviceUDID", target.udid]
                _ = try await NSWorkspace.shared.openApplication(at: simulator, configuration: configuration)
                self.error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
