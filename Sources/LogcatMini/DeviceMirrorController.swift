import AppKit
import AVFoundation
import Combine
import LogcatCore

@MainActor final class DeviceMirrorController: ObservableObject {
    enum State: Equatable { case idle, connecting, streaming, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var deviceName = ""
    @Published private(set) var serial = ""
    @Published private(set) var keyboardNotice: String?
    @Published private(set) var needsKeyboardSettings = false
    @Published var hideSoftKeyboard: Bool {
        didSet {
            defaults.set(hideSoftKeyboard, forKey: "mirror.hideSoftKeyboard")
            applyKeyboardPreference()
        }
    }
    private let defaults: UserDefaults
    private var keyboardTask: Task<Void, Never>?
    // Frames do not publish through SwiftUI or invalidate the live log table.
    let frames = MirrorFrameDelivery()
    let installer = DeviceAPKInstaller()
    @Published var draggingAPK = false
    private var session: MirrorSession?
    private var sessions: [MirrorSession] = []
    private var generation = UUID()
    private var currentPath: String?
    private var requested = false
    var isStreaming: Bool { state == .streaming }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideSoftKeyboard = defaults.bool(forKey: "mirror.hideSoftKeyboard")
    }

    func connect(path: String?, device: AndroidDevice?) {
        stop()
        requested = true
        serial = device?.id ?? ""; deviceName = device?.name ?? ""
        currentPath = path
        guard let path else { state = .failed("请先在设置中选择 ADB。"); return }
        guard let device, device.ready else { state = .failed("请连接手机并允许 USB 调试，然后重连投屏。"); return }
        let resources = Bundle.main.url(forResource: "LogcatMini_LogcatMini", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let runtime = resources.url(forResource: "Recording", withExtension: nil),
              FileManager.default.fileExists(atPath: runtime.appendingPathComponent("scrcpy-server").path) else {
            state = .failed("投屏组件缺失，请重新构建或安装 Logcat Mini。"); return
        }
        state = .connecting
        let token = generation
        let session = MirrorSession(path: path, serial: device.id, server: runtime.appendingPathComponent("scrcpy-server"))
        frames.activate(token) { [weak self] pixel in
            guard let self, self.generation == token else { return }
            let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
            if self.videoSize != size { self.videoSize = size }
            if self.state != .streaming {
                self.state = .streaming
                self.applyKeyboardPreference()
            }
        }
        session.onFrame = { [weak frames] pixel in frames?.submit(pixel, generation: token) }
        session.onKeyboardNotice = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.hideSoftKeyboard else { return }
                self.keyboardNotice = message
            }
        }
        session.onEnd = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.session?.stop(); self.session = nil; self.frames.clear(); self.videoSize = .zero
                self.clearKeyboardStatus()
                self.state = .failed(message)
            }
        }
        sessions.removeAll(where: \.isFinished); sessions.append(session)
        self.session = session; session.start()
    }

    func updateTarget(path: String?, device: AndroidDevice?) {
        guard requested else { return }
        if path != currentPath || (device != nil && serial != device?.id) {
            connect(path: path, device: device)
        } else if device?.ready != true, state == .connecting || state == .streaming {
            session?.stop(); session = nil; generation = UUID(); frames.clear(); videoSize = .zero
            clearKeyboardStatus()
            state = .failed("手机已断开或尚未授权。连接后点击重连，日志仍保留在左侧。")
        }
    }

    func stop() {
        requested = false; generation = UUID(); session?.stop(); session = nil
        frames.clear(); videoSize = .zero; state = .idle
        clearKeyboardStatus()
        draggingAPK = false
    }

    var hasPendingSessions: Bool { sessions.contains { !$0.isFinished } || installer.isInstalling }
    func finishBeforeQuit() async {
        stop()
        for session in sessions { session.stop(); await session.waitUntilFinished() }
        sessions.removeAll()
        await installer.waitUntilFinished()
    }

    var apkTarget: APKInstallTarget? {
        guard isStreaming, let currentPath, !serial.isEmpty, !installer.isInstalling else { return nil }
        return APKInstallTarget(path: currentPath, serial: serial, name: deviceName)
    }
    @discardableResult func installAPK(_ url: URL, target: APKInstallTarget) -> Bool {
        guard apkTarget == target else {
            installer.reportFailure("投屏设备已变化或断开，请确认目标手机后重新拖入 APK。"); return false
        }
        return installer.install(url, on: target)
    }

    func send(_ data: Data) { guard isStreaming else { return }; session?.send(data) }
    func key(_ code: UInt32) { send(MirrorProtocol.key(code)) }
    func openKeyboardSettings() { send(MirrorProtocol.openKeyboardSettings) }

    private func clearKeyboardStatus() {
        keyboardTask?.cancel(); keyboardTask = nil
        keyboardNotice = nil; needsKeyboardSettings = false
    }

    private func applyKeyboardPreference() {
        clearKeyboardStatus()
        guard isStreaming, let session, let path = currentPath else { return }
        guard hideSoftKeyboard else { session.setHideSoftKeyboard(false); return }
        // UHID remains the default. The session owns any OEM compatibility lease.
        keyboardTask = Task { [weak self] in
            do {
                let support = try await ADB.run(path: path, arguments: ["-s", session.serial, "shell",
                    "if [ -r /dev/uhid ] && [ -w /dev/uhid ]; then echo supported; fi"])
                guard !Task.isCancelled, let self, self.session === session else { return }
                guard support == "supported" else {
                    self.keyboardNotice = "这台手机不支持隐藏软键盘，仍可正常投屏和发送文字。"
                    return
                }
                session.setHideSoftKeyboard(true)
                let showIME = try await ADB.run(path: path, arguments: ["-s", session.serial, "shell", "settings", "get", "secure", "show_ime_with_hard_keyboard"])
                guard !Task.isCancelled, self.session === session else { return }
                if showIME == "1" {
                    self.needsKeyboardSettings = true
                    self.keyboardNotice = "手机允许外接键盘时显示软键盘，请在手机键盘设置中关闭「使用屏幕键盘」。"
                }
            } catch {
                guard !Task.isCancelled, let self, self.session === session else { return }
                self.keyboardNotice = "暂时无法确认手机键盘状态，请关闭此开关后重试。"
            }
        }
    }
    @discardableResult func sendText(_ value: String, paste: Bool = true) -> Bool {
        guard isStreaming, let data = MirrorProtocol.text(value, paste: paste) else { return false }
        send(data); return true
    }
}

/// A single pending decoded frame bounds memory even while the log UI is busy.
final class MirrorFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var token = UUID()
    private var pending: CVPixelBuffer?
    private var scheduled = false
    @MainActor private var onFrame: ((CVPixelBuffer) -> Void)?
    @MainActor var display: ((CVPixelBuffer?) -> Void)?
    @MainActor private(set) var latest: CVPixelBuffer?
    @MainActor func activate(_ token: UUID, onFrame: @escaping (CVPixelBuffer) -> Void) {
        clear(); lock.lock(); self.token = token; lock.unlock(); self.onFrame = onFrame
    }
    func submit(_ pixel: CVPixelBuffer, generation: UUID) {
        lock.lock()
        guard token == generation else { lock.unlock(); return }
        pending = pixel
        if scheduled { lock.unlock(); return }
        scheduled = true; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.deliver() }
    }
    @MainActor private func deliver() {
        lock.lock(); let pixel = pending; pending = nil; scheduled = false; lock.unlock()
        if let pixel { latest = pixel; onFrame?(pixel); display?(pixel) }
    }
    @MainActor func clear() {
        lock.lock(); token = UUID(); pending = nil; lock.unlock()
        latest = nil; onFrame = nil; display?(nil)
    }
}
