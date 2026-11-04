import AppKit
import Combine
import LogcatCore

/// iOS transports share the log viewer, but own their processes and sessions independently of ADB.
@MainActor final class IOSLogViewModel: ObservableObject {
    let logs: LogViewModel
    let media = IOSMediaController()
    let preview = IOSPreviewController()
    let builds: IOSBuildController
    private let defaults: UserDefaults
    @Published var previewShown = false
    var previewActive = true
    @Published private(set) var favoriteApps: [IOSLogProcess] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published var includeSystem = false { didSet { defaults.set(includeSystem, forKey: "ios.includeSystem") } }
    @Published var infoShown = false
    @Published var infoText = ""
    @Published var infoLoading = false
    @Published var deviceActionError: String?
    @Published var clipboardBusy = false
    private var iconTask: Task<Void, Never>?
    @Published private(set) var devices: [IOSDevice] = []
    @Published private(set) var processes: [IOSLogProcess] = []
    @Published private(set) var refreshing = false
    @Published private(set) var loadingProcesses = false
    @Published var processInput = ""
    @Published var discoveryNotice: String?
    private var session = UUID()
    private var processRequest = UUID()
    private let stream = LogStream()
    private let inbox = LogInbox()
    private var timer: Timer?
    private var pollTimer: Timer?
    private var names: [String: String] = [:]
    private var began = false
    private var logChanges: AnyCancellable?

    init(defaults: UserDefaults = UserDefaults(suiteName: "com.songran.LogcatMini.iOS")!) {
        self.defaults = defaults
        logs = LogViewModel(defaults: defaults)
        builds = IOSBuildController(defaults: defaults)
        favoriteApps = defaults.data(forKey: "ios.favoriteMetadata").flatMap { try? JSONDecoder().decode([IOSLogProcess].self, from: $0) } ?? []
        includeSystem = defaults.bool(forKey: "ios.includeSystem")
        logs.adbPath = nil
        processInput = logs.selectedPackage
        logChanges = logs.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        builds.onInstalled = { [weak self] device, id in
            guard let self, self.device?.id == device.id else { return }
            await self.refreshProcesses()
            guard self.device?.id == device.id, let app = self.processes.first(where: { $0.id == id }) else { return }
            self.selectApp(app); if !self.logs.running { self.start() }
        }
    }
    var device: IOSDevice? { devices.first { $0.id == logs.selectedSerial } }
    var canStart: Bool {
        guard let device else { return false }
        if !logs.selectedPackage.isEmpty && !logs.selectedPackage.hasPrefix("process:"), !processes.contains(where: { $0.id == logs.selectedPackage }) { return false }
        return IOSTools.locate(device.kind == .simulator ? "xcrun" : "idevicesyslog") != nil
    }
    var selectedApp: IOSLogProcess? { processes.first { $0.id == logs.selectedPackage } ?? favoriteApps.first { $0.id == logs.selectedPackage } }
    var sessionTitle: String { selectedApp?.name ?? (logs.selectedPackage.isEmpty ? "全部应用" : processInput) }
    func toggleFavorite(_ app: IOSLogProcess) {
        logs.toggleFavorite(app.id)
        favoriteApps.removeAll { $0.id == app.id }
        if logs.favorites.contains(app.id) { favoriteApps.append(app) }
        defaults.set(try? JSONEncoder().encode(favoriteApps), forKey: "ios.favoriteMetadata")
        loadIcons()
    }
    func selectApp(_ app: IOSLogProcess?) {
        let resume = logs.running
        stop(); logs.selectPackage(app?.id ?? "", startCapture: false); processInput = app?.executable ?? ""
        if resume { start() }
        loadIcons()
    }
    func togglePreview() {
        if previewShown { previewShown = false; preview.stop() }
        else if let device { previewShown = true; preview.connect(device) }
    }
    func takeScreenshot(copyOnly: Bool = false) { if let device { media.screenshot(device, copyOnly: copyOnly) } }
    func transferClipboard(toDevice: Bool) {
        guard let device, !clipboardBusy else { return }
        clipboardBusy = true; deviceActionError = nil
        Task {
            defer { clipboardBusy = false }
            do { try await IOSDeviceService.transferClipboard(device: device, toDevice: toDevice); media.notice = toDevice ? "剪贴板已发送到 \(device.name)，可在设备中粘贴。" : "已复制 \(device.name) 的剪贴板。" }
            catch { deviceActionError = "剪贴板传输失败：\(error.localizedDescription)" }
        }
    }
    func toggleRecording() {
        if media.recording { media.stopRecording() }
        else if media.canRetry { media.retrySave() }
        else if let device { media.startRecording(device) }
    }
    func showDeviceInfo() {
        guard let device else { return }; infoShown = true; infoText = ""; infoLoading = true
        Task {
            do { let text = try await IOSDeviceService.deviceInfo(device); guard self.device?.id == device.id else { return }; infoText = text }
            catch { guard self.device?.id == device.id else { return }; infoText = error.localizedDescription }
            infoLoading = false
        }
    }
    private func loadIcons() {
        iconTask?.cancel()
        guard let device else { return }
        let requested = processes.filter { logs.favorites.contains($0.id) || $0.id == logs.selectedPackage }
        iconTask = Task {
            for app in requested where icons[app.id] == nil {
                let data = await IOSDeviceService.icon(app, device: device)
                guard !Task.isCancelled, self.device?.id == device.id else { return }
                if let data, let image = NSImage(data: data) { icons[app.id] = image }
                else if device.kind == .simulator, let path = app.bundlePath { icons[app.id] = NSWorkspace.shared.icon(forFile: path) }
            }
        }
    }
    func begin() {
        guard !began else { return }; began = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flush() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshDevices() }
        }
        Task { await refreshDevices() }
    }
    func shutdown() {
        iconTask?.cancel(); preview.stop()
        stop(); timer?.invalidate(); pollTimer?.invalidate(); timer = nil; pollTimer = nil; began = false
        logs.shutdown()
    }
    func refreshDevices() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        // Failure or missing dependencies for one transport must not hide the other.
        async let simulatorResult = Self.simulators()
        async let usbResult = Self.usbIDs()
        let (simulators, usb) = await (simulatorResult, usbResult)
        var updated = simulators.devices
        for udid in usb.ids {
            if names[udid] == nil, let tool = IOSTools.locate("idevicename"),
               let name = try? await ADB.run(path: tool, arguments: ["-u", udid], timeout: 3), !name.isEmpty {
                names[udid] = name
            }
            updated.append(IOSDevice(udid: udid, name: names[udid] ?? "iPhone / iPad", kind: .usb))
        }
        updated.sort { $0.id < $1.id }
        let wasPresent = device != nil
        if devices != updated { devices = updated }
        let notice = [simulators.notice, usb.notice].compactMap { $0 }.joined(separator: "\n")
        if discoveryNotice != (notice.isEmpty ? nil : notice) { discoveryNotice = notice.isEmpty ? nil : notice }
        if device == nil { preview.stop() }
        else if previewActive && previewShown, preview.target?.id != device?.id, let device { preview.connect(device) }
        if logs.selectedSerial.isEmpty, let first = devices.first {
            await selectDevice(first.id)
        } else if device == nil, logs.running {
            stop(); logs.errorMessage = "iOS 设备已断开或模拟器已关闭，日志已保留。重新连接后点击开始采集。"
        } else if !wasPresent, device != nil {
            await refreshProcesses()
        }
    }
    private static func simulators() async -> (devices: [IOSDevice], notice: String?) {
        guard let path = IOSTools.locate("xcrun") else { return ([], "模拟器需要安装 Xcode，并先在 Simulator 中启动 iPhone 或 iPad。") }
        do {
            let output = try await ADB.run(path: path, arguments: ["simctl", "list", "devices", "booted", "--json"], timeout: 10)
            return (try IOSDevice.bootedSimulators(Data(output.utf8)), nil)
        } catch { return ([], "模拟器连接不可用：\(error.localizedDescription)") }
    }
    private static func usbIDs() async -> (ids: [String], notice: String?) {
        guard let tool = IOSTools.locate("idevice_id"), IOSTools.locate("idevicesyslog") != nil else {
            return ([], "真机连接组件未安装。请在终端运行 brew install libimobiledevice，然后刷新设备。")
        }
        do {
            let output = try await ADB.run(path: tool, arguments: ["-l"], timeout: 5)
            return (output.split(whereSeparator: \.isNewline).map(String.init), nil)
        } catch { return ([], "USB 设备发现失败：\(error.localizedDescription)") }
    }
    func selectDevice(_ id: String) async {
        guard logs.selectedSerial != id else { return }
        stop(); logs.activateDevice(id); processInput = logs.selectedPackage
        defaults.set(id, forKey: "selectedSerial")
        icons = [:]; iconTask?.cancel(); infoShown = false; infoLoading = false
        preview.stop(); if previewShown, let device { preview.connect(device) }
        processes = []; processRequest = UUID(); loadingProcesses = false
        await refreshProcesses()
    }
    func refreshProcesses() async {
        guard let device else { return }
        let request = UUID(); processRequest = request; loadingProcesses = true
        do {
            let result: [IOSLogProcess]
            if device.kind == .simulator {
                let output = try await ADB.run(path: "/usr/bin/xcrun", arguments: ["simctl", "listapps", device.udid], timeout: 12)
                result = try IOSLogProcess.simulatorApps(Data(output.utf8))
            } else if let path = IOSTools.locate("idevicesyslog") {
                do {
                    let data = try await IOSDeviceService.json(["device", "info", "apps", "--device", device.udid, "--include-all-apps"])
                    result = try IOSLogProcess.installedDeviceApps(data)
                } catch {
                    let output = try await ADB.run(path: path, arguments: ["-u", device.udid, "--no-colors", "pidlist"], timeout: 8)
                    result = IOSLogProcess.deviceProcesses(output)
                    discoveryNotice = "应用列表不可用，当前显示运行中的进程；安装与图标功能需要 Xcode 设备支持。"
                }
            } else { result = [] }
            guard processRequest == request, self.device?.id == device.id else { return }
            processes = result; loadingProcesses = false
            // 0.18 stored the executable as the selection. Move that preference to
            // the bundle identity when unambiguous, otherwise preserve a manual process session.
            if !logs.selectedPackage.isEmpty, !logs.selectedPackage.hasPrefix("process:"),
               !logs.selectedPackage.contains("."), !result.contains(where: { $0.id == logs.selectedPackage }) {
                let matches = result.filter { $0.executable == logs.selectedPackage }
                if matches.count == 1 { selectApp(matches[0]) } else { selectProcess(logs.selectedPackage) }
            }
            if let app = selectedApp { processInput = app.executable }
            else if logs.selectedPackage.hasPrefix("process:") { processInput = String(logs.selectedPackage.dropFirst(8)) }
            else if !logs.selectedPackage.isEmpty && logs.running { stop(); logs.errorMessage = "当前应用未在设备上找到，日志已保留。" }
            for app in result where logs.favorites.contains(app.id) {
                favoriteApps.removeAll { $0.id == app.id }; favoriteApps.append(app)
            }
            defaults.set(try? JSONEncoder().encode(favoriteApps), forKey: "ios.favoriteMetadata")
            loadIcons()
        } catch {
            guard processRequest == request, self.device?.id == device.id else { return }
            loadingProcesses = false
            logs.errorMessage = "应用 / 进程列表读取失败，可手动填写进程名：\(error.localizedDescription)"
        }
    }
    func selectProcess(_ executable: String) {
        let resume = logs.running
        stop(); processInput = executable
        let value = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        logs.selectPackage(value.isEmpty ? "" : "process:" + value, startCapture: false)
        if resume { start() }
    }
    func start() {
        guard canStart, let device, let path = IOSTools.locate(device.kind == .simulator ? "xcrun" : "idevicesyslog") else { return }
        stop()
        let process = processInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !process.contains("\n"), !process.contains("\r"), !process.contains("\0"), !process.contains("|") else {
            logs.errorMessage = "请填写一个进程名或 PID，不包含换行或 |。"; return
        }
        if selectedApp?.executable != process {
            logs.selectPackage(process.isEmpty ? "" : "process:" + process, startCapture: false)
        }
        logs.errorMessage = nil
        let generation = UUID(); session = generation; inbox.reset(generation)
        let format: LogInbox.Format = device.kind == .simulator ? .iosSimulator : .iosDevice
        do {
            let processPath = selectedApp?.bundlePath.map { URL(fileURLWithPath: $0).appendingPathComponent(process).path }
            try stream.start(path: path, arguments: IOSTools.streamArguments(device: device, process: process, processPath: processPath), onLines: { [inbox] lines in
                inbox.receive(lines, session: generation, format: format)
            }, onExit: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self, self.session == generation else { return }
                    self.flush(limit: nil); self.logs.running = false
                    self.logs.errorMessage = "iOS 日志连接已结束：\(reason)"
                }
            })
            logs.running = true
        } catch { logs.errorMessage = error.localizedDescription }
    }
    func stop() {
        stream.stop(); flush(limit: nil); session = UUID(); inbox.reset(session); logs.running = false
    }
    func toggleCapture() { if logs.running { stop() } else { start() } }
    func clear() { _ = inbox.drain(); logs.clear() }
    private func flush(limit: Int? = 1_000) {
        let (entries, lost) = inbox.drain(limit: limit)
        if !entries.isEmpty || lost > 0 { logs.ingest(entries, lost: lost) }
    }
}
