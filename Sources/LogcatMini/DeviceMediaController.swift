import AppKit
import Combine
import LogcatCore

@MainActor final class DeviceMediaController: ObservableObject {
    let library: MediaLibrary
    @Published private(set) var takingScreenshot = false
    @Published private(set) var recording = false
    @Published private(set) var saving = false
    @Published private(set) var recordingDevice = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var lastSaved: URL?
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var canRetry = false
    private var session: AndroidScreenRecording?
    private var destination: URL?
    private var saveTask: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?
    private var timer: Timer?
    private var recordedDevice: AndroidDevice?
    private var recordingStarted: Date?
    var busy: Bool { recording || saving || canRetry }
    var elapsedText: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }

    init(library: MediaLibrary? = nil) { self.library = library ?? MediaLibrary() }
    private func chooseDestination(_ kind: CaptureKind, device: AndroidDevice) -> URL? {
        do { return try library.destination(for: kind, serial: device.id) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func copyScreenshot(path: String, device: AndroidDevice) {
        guard !takingScreenshot, device.ready else { return }
        takingScreenshot = true; error = nil; notice = nil
        screenshotTask = Task {
            defer { takingScreenshot = false }
            do {
                let data = try await DeviceCapture.screenshotData(path: path, serial: device.id)
                try ScreenshotClipboard.copy(data)
                notice = "截图已复制，可直接粘贴到聊天窗口。"
            } catch { self.error = "\(device.name) 截图复制失败：\(error.localizedDescription)" }
        }
    }
    func screenshot(path: String, device: AndroidDevice) {
        guard !takingScreenshot, let url = chooseDestination(.screenshot, device: device) else { return }
        takingScreenshot = true; error = nil; notice = nil
        let capturedAt = Date()
        screenshotTask = Task {
            defer { takingScreenshot = false }
            do {
                try await DeviceCapture.screenshot(path: path, serial: device.id, to: url); lastSaved = url
                library.add(kind: .screenshot, url: url, deviceName: device.name, serial: device.id, createdAt: capturedAt)
                do {
                    try ScreenshotClipboard.copyFile(url)
                    notice = "截图已保存并复制，可直接粘贴到聊天窗口。"
                } catch {
                    self.error = "截图已保存，但复制到剪贴板失败：\(error.localizedDescription)"
                }
            }
            catch { self.error = "\(device.name) 截图失败：\(error.localizedDescription)" }
        }
    }
    func startRecording(path: String, device: AndroidDevice) {
        guard !busy, let url = chooseDestination(.recording, device: device) else { return }
        do {
            let resources = Bundle.main.url(forResource: "LogcatMini_LogcatMini", withExtension: "bundle")
                .flatMap { Bundle(url: $0) } ?? Bundle.module
            guard let runtime = resources.url(forResource: "Recording", withExtension: nil) else {
                throw ADBError.failed("录屏组件缺失，请重新安装 Logcat Mini。")
            }
            let session = try AndroidScreenRecording(path: path, serial: device.id, runtime: runtime)
            self.session = session; destination = url; recordingDevice = "\(device.name) · \(device.id)"
            recordedDevice = device
            error = nil; elapsed = 0; recording = true; saving = false
            let began = Date()
            recordingStarted = began
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor [weak controller] in controller?.elapsed = Int(Date().timeIntervalSince(began)) }
            }
            awaitSave(session, to: url)
        } catch { self.error = error.localizedDescription }
    }
    private func awaitSave(_ session: AndroidScreenRecording, to url: URL) {
        saveTask = Task {
            do {
                try await session.saveWhenFinished(to: url)
                if let device = recordedDevice {
                    library.add(kind: .recording, url: url, deviceName: device.name, serial: device.id,
                                createdAt: recordingStarted ?? Date(), duration: elapsed)
                }
                self.lastSaved = url; self.session = nil; canRetry = false
            } catch { self.error = error.localizedDescription; canRetry = true }
            timer?.invalidate(); timer = nil; recording = false; saving = false
        }
    }
    func stopRecording() {
        guard let session, recording, !saving else { return }
        saving = true
        Task { do { try await session.stop() } catch { self.error = error.localizedDescription; saving = false } }
    }
    func retrySave() {
        guard let session, let device = recordedDevice, canRetry, !saving,
              let url = chooseDestination(.recording, device: device) else { return }
        destination = url
        canRetry = false; saving = true; error = nil; awaitSave(session, to: url)
    }
    func dismissRetry() { guard canRetry, !saving else { return }; session = nil; destination = nil; canRetry = false }
    func revealSaved() { if let lastSaved { NSWorkspace.shared.activateFileViewerSelecting([lastSaved]) } }
    func finishBeforeQuit() async -> Bool {
        await screenshotTask?.value
        if let session, session.isRunning {
            do { try await session.stop() } catch { self.error = error.localizedDescription; return false }
        }
        await saveTask?.value
        return !canRetry
    }
}
