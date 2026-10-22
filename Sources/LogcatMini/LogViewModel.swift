import AppKit
import Combine
import LogcatCore

final class LogInbox {
    private let lock = NSLock()
    private var session = UUID()
    private var nextID: UInt64 = 0
    private var pending: [LogEntry] = []
    private var consumed = 0
    private var previous: LogEntry?
    private var dropped = 0
    func reset(_ id: UUID) { lock.lock(); defer { lock.unlock() }; session = id; pending.removeAll(); consumed = 0; previous = nil; dropped = 0 }
    func receive(_ lines: [String], session id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard session == id else { return }
        for line in lines {
            if line.hasPrefix("---------") || line.isEmpty { continue }
            nextID += 1
            if let parsed = LogParser.parse(line, id: nextID) { pending.append(parsed); previous = parsed }
            else if let p = previous {
                pending.append(LogEntry(id: nextID, date: p.date, time: p.time, pid: p.pid, tid: p.tid, level: p.level, tag: p.tag, message: line, raw: line))
            }
        }
    }
    func drain(limit: Int? = nil) -> ([LogEntry], Int) {
        lock.lock(); defer { lock.unlock() }
        let end = min(pending.count, consumed + (limit ?? (pending.count - consumed)))
        let result = (Array(pending[consumed..<end]), dropped); consumed = end; dropped = 0
        if consumed == pending.count { pending.removeAll(keepingCapacity: true); consumed = 0 }
        else if consumed >= 4096 && consumed >= pending.count / 2 { pending.removeFirst(consumed); consumed = 0 }
        return result
    }
}

@MainActor final class LogViewModel: ObservableObject {
    enum FindPane { case list, detail }
    let listFind = LogFindState()
    let detailFind = LogFindState()
    let media = DeviceMediaController()
    let mirror: DeviceMirrorController
    let builds: LocalBuildController
    var localBuildTarget: LocalBuildController.Target? {
        guard let path = adbPath, let device, device.ready else { return nil }
        return .init(adb: path, serial: device.id, name: device.name)
    }
    @Published var mirrorShown = false
    func connectMirror() { mirror.connect(path: adbPath, device: device) }
    func toggleMirror() {
        if mirrorShown { closeMirror() } else { mirrorShown = true; connectMirror() }
    }
    func closeMirror() { mirrorShown = false; mirror.stop() }
    var activeFindPane = FindPane.list
    private var findSubscription: AnyCancellable?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mirror = DeviceMirrorController(defaults: defaults)
        builds = LocalBuildController(defaults: defaults)
        filterHistory = FilterHistory(defaults: defaults)
        selectedSerial = defaults.string(forKey: "selectedSerial") ?? ""
        selectedPackage = defaults.string(forKey: "selectedPackage") ?? ""
        adbPath = ADB.locate(custom: defaults.string(forKey: "adbPath"))
        favorites = PackageFavorites(defaults: defaults)
        includeSystem = defaults.bool(forKey: "apps.includeSystem")
        mirror.installer.onInstalled = { [weak self] serial in
            Task { @MainActor [weak self] in
                guard let self, self.selectedSerial == serial else { return }
                await self.refreshPackages()
            }
        }
        builds.onInstalled = { [weak self] target, package in
            guard let self, self.selectedSerial == target.serial else { return }
            await self.refreshPackages()
            guard self.selectedSerial == target.serial else { return }
            self.selectPackage(package)
            if !self.running { self.start() }
        }
        mirror.installer.installationAllowed = { [weak self] in self?.builds.busy != true }
        builds.installationAllowed = { [weak self] in self?.mirror.installer.isInstalling != true }
        findSubscription = listFind.$query.dropFirst().debounce(for: .milliseconds(120), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.rebuildListFind()
        }
    }
    var currentFind: LogFindState { inspectorFullscreen || (activeFindPane == .detail && selectedLog != nil) ? detailFind : listFind }
    func openFind(_ pane: FindPane? = nil) {
        if let pane { activeFindPane = pane }
        if currentFind === listFind { follow = false }
        currentFind.open()
    }
    func toggleFind() {
        if currentFind.shown { currentFind.close() } else { openFind() }
    }
    func closeFind() -> Bool {
        guard currentFind.shown else { return false }
        currentFind.close(); return true
    }
    private func rebuildListFind() {
        let term = listFind.query
        listFind.replaceMatches(term.isEmpty ? [] : visible.filter { $0.fullText.range(of: term, options: .caseInsensitive) != nil }.map { String($0.id) })
    }
    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial = "" { didSet { mirror.updateTarget(path: adbPath, device: device) } }
    @Published var packages: [AndroidPackage] = []
    @Published var selectedPackage = ""
    @Published var appSearch = ""
    @Published var logFullscreen = false
    @Published var inspectorFullscreen = false
    @Published var detailFormatted = false
    @Published var canFormatDetail = false
    func toggleDetailFormatting() {
        guard selectedLog != nil, canFormatDetail else { return }
        detailFormatted.toggle(); activeFindPane = .detail
    }
    func takeScreenshot(copy: Bool = false) {
        guard let path = adbPath, let device, device.ready else { return }
        if copy { media.copyScreenshot(path: path, device: device) }
        else { media.screenshot(path: path, device: device) }
    }
    func toggleRecording() {
        if media.saving { return }
        if media.recording { media.stopRecording() }
        else if media.canRetry { media.retrySave() }
        else if let path = adbPath, let device, device.ready { media.startRecording(path: path, device: device) }
    }
    @Published private(set) var favorites = PackageFavorites()
    @Published private(set) var favoriteMetadata: [String: AppMetadata] = [:]
    @Published private(set) var favoriteIcons: [String: NSImage] = [:]
    @Published private(set) var loadingFavoriteMetadata = false
    @Published private(set) var favoriteMetadataNotice: String?
    @Published var includeSystem = false { didSet { defaults.set(includeSystem, forKey: "apps.includeSystem") } }
    @Published var loadingApps = false
    @Published var minimum = LogLevel.verbose { didSet { applyFilters() } }
    @Published private(set) var filterHistory: FilterHistory
    private var lastRememberedFilter: SavedLogFilter?
    var currentFilter: SavedLogFilter { SavedLogFilter(query: query, tag: tag, regex: regex, minimum: minimum.rank) }
    func rememberFilter() {
        let current = currentFilter
        guard current.canSave, current != lastRememberedFilter else { return }
        filterHistory.remember(current); lastRememberedFilter = current
    }
    func toggleFilterFavorite() { filterHistory.toggleFavorite(currentFilter) }
    func clearFilterHistory() { filterHistory.clearRecent(); lastRememberedFilter = currentFilter }
    func restoreFilter(_ saved: SavedLogFilter) {
        rememberFilter()
        query = saved.query; tag = saved.tag; regex = saved.regex
        minimum = LogLevel.allCases[saved.minimum]
        rememberFilter()
    }
    @Published var query = "" { didSet { scheduleFilter() } }
    @Published var tag = "" { didSet { scheduleFilter() } }
    @Published var regex = false { didSet { applyFilters() } }
    @Published var filterError: String?
    @Published var errorMessage: String?
    @Published var visible: [LogEntry] = []
    @Published var revision = 0
    @Published var selectedLog: LogEntry? {
        didSet {
            if selectedLog?.id != oldValue?.id || selectedLog?.mergedParts != oldValue?.mergedParts {
                detailFormatted = false; canFormatDetail = false
            }
            if selectedLog == nil { inspectorFullscreen = false; activeFindPane = .list; detailFind.close() }
        }
    }
    @Published var running = false
    @Published var follow = true
    @Published var paused = false
    @Published var totalCount = 0
    @Published var evicted = 0
    @Published var errorCount = 0
    @Published var receivedWhilePaused = 0
    @Published var adbPath: String? { didSet { mirror.updateTarget(path: adbPath, device: device) } }
    @Published var notice = ""
    private var buffer = LogBuffer()
    private struct SessionKey: Hashable {
        var serial: String
        var package: String
    }
    private struct AppSession {
        var buffer: LogBuffer
        var errors: Int
        var pendingLoss: Int
        var filter: SavedLogFilter
        var selectedLog: LogEntry?
        var follow: Bool
    }
    private var appSessions: [SessionKey: AppSession] = [:]
    private var devicePackages: [String: String] = [:]
    private var sessionKey: SessionKey { SessionKey(serial: selectedSerial, package: selectedPackage) }
    private var restoringSession = false
    private var appliedFilter: SavedLogFilter?
    private var capturedUID: String?
    private let stream = LogStream()
    private let inbox = LogInbox()
    private var generation = UUID()
    private var packageRequest = UUID()
    private var timer: Timer?
    private var pollTimer: Timer?
    private var filterTask: Task<Void, Never>?
    private var refreshing = false
    private var began = false
    private var pendingLoss = 0
    private var pausedSnapshot: [LogEntry] = []
    private var metadataTask: Task<Void, Never>?
    private var metadataRequest = UUID()
    private var metadataSerial = ""
    private let metadataService: AppMetadataService? = {
        let resources = Bundle.main.url(forResource: "LogcatMini_LogcatMini", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let helper = resources.url(forResource: "AppMetadata", withExtension: "jar") else { return nil }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logcat Mini/AppMetadata", isDirectory: true)
        return AppMetadataService(helperURL: helper, cacheDirectory: directory)
    }()

    var device: AndroidDevice? { devices.first { $0.id == selectedSerial } }
    var package: AndroidPackage? { packages.first { $0.id == selectedPackage } }
    var matchingApps: [AndroidPackage] {
        let matches = packages.filter { !favorites.contains($0.id) && (appSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(appSearch)) }
        guard let current = matches.first(where: { $0.id == selectedPackage }) else { return matches }
        return [current] + matches.filter { $0.id != current.id }
    }
    var matchingFavoriteIDs: [String] {
        favorites.packageIDs.filter {
            appSearch.isEmpty || $0.localizedCaseInsensitiveContains(appSearch) ||
            favoriteMetadata[$0]?.label.localizedCaseInsensitiveContains(appSearch) == true
        }
    }
    func toggleFavorite(_ packageID: String) {
        favorites.toggle(packageID)
        if favorites.contains(packageID) { refreshFavoriteMetadata() }
    }
    func isPackageListed(_ packageID: String) -> Bool { packages.contains { $0.id == packageID } }
    var sessionTitle: String { selectedPackage.isEmpty ? "全部应用日志" : selectedPackage }
    func requestContext(for entry: LogEntry) -> [LogEntry] {
        let source = paused ? pausedSnapshot : buffer.entries
        guard let index = source.firstIndex(where: { $0.id == entry.id }) else { return [entry] }
        return Array(source[max(0, index - 600)..<min(source.count, index + 601)])
    }
    func toggleLogFullscreen() { logFullscreen.toggle() }
    var canStart: Bool { adbPath != nil && device?.ready == true && !loadingApps && (selectedPackage.isEmpty || package != nil) }

    func begin() {
        guard !began else { return }; began = true
        refreshFavoriteMetadata(readDevice: false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let model = self else { return }; Task { @MainActor [weak model] in model?.flush() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let model = self else { return }; Task { @MainActor [weak model] in await model?.refreshDevices() }
        }
        Task { await refreshDevices() }
    }
    func shutdown() { mirror.stop(); rememberFilter(); filterTask?.cancel(); metadataTask?.cancel(); stream.stop(); timer?.invalidate(); pollTimer?.invalidate() }

    private func refreshFavoriteMetadata(readDevice: Bool = true) {
        metadataTask?.cancel()
        let request = UUID(), serial = selectedSerial
        metadataRequest = request; favoriteMetadataNotice = nil
        if metadataSerial != serial {
            metadataSerial = serial; favoriteMetadata = [:]; favoriteIcons = [:]
        }
        let ids = favorites.packageIDs.filter { isPackageListed($0) }
        let path = readDevice && device?.ready == true && !ids.isEmpty ? adbPath : nil
        loadingFavoriteMetadata = path != nil
        guard !serial.isEmpty, let service = metadataService else {
            loadingFavoriteMetadata = false; return
        }
        metadataTask = Task { [weak self] in
            let cached = await service.cached(serial: serial)
            guard let self, !Task.isCancelled, self.metadataRequest == request, self.selectedSerial == serial else { return }
            self.applyFavoriteMetadata(cached)
            guard let path else { return }
            do {
                let refreshed = try await service.refresh(adbPath: path, serial: serial, packageIDs: ids)
                guard !Task.isCancelled, self.metadataRequest == request, self.selectedSerial == serial else { return }
                self.applyFavoriteMetadata(refreshed)
                self.loadingFavoriteMetadata = false
            } catch {
                guard !Task.isCancelled, self.metadataRequest == request else { return }
                self.loadingFavoriteMetadata = false
                self.favoriteMetadataNotice = "名称和图标暂未更新，可点击设备旁的刷新按钮重试"
            }
        }
    }

    private func applyFavoriteMetadata(_ values: [String: AppMetadata]) {
        favoriteMetadata = values
        favoriteIcons = values.reduce(into: [:]) { icons, pair in
            if let data = pair.value.iconPNG, let image = NSImage(data: data) { icons[pair.key] = image }
        }
    }

    func refreshDevices() async {
        guard !refreshing, let path = adbPath else {
            if adbPath == nil { errorMessage = "未找到 ADB。请点击左下角选择 Android SDK 中的 adb。" }
            return
        }
        refreshing = true; defer { refreshing = false }
        do {
            let output = try await ADB.run(path: path, arguments: ["devices", "-l"])
            let updated = AndroidDevice.parse(output)
            let wasReady = device?.ready == true
            if devices != updated { devices = updated }
            mirror.updateTarget(path: adbPath, device: device)
            if selectedSerial.isEmpty, let first = updated.first(where: \.ready) {
                await selectDevice(first.id)
            } else if device?.ready == true && (!wasReady || packages.isEmpty && !loadingApps) {
                await refreshPackages()
            } else if device?.ready != true && running {
                stop(); errorMessage = device?.state == "unauthorized" ? "请在手机上允许 USB 调试，然后等待重新连接。" : "手机已断开连接，已保留当前日志。"
            } else if running && !loadingApps && !selectedPackage.isEmpty {
                await verifyCapturePackage(path: path)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Reinstalling an app can change its UID without changing the connected device.
    private func verifyCapturePackage(path: String) async {
        let serial = selectedSerial, id = selectedPackage, session = generation
        do {
            let output = try await ADB.run(path: path, arguments: ["-s", serial, "shell", "cmd", "package", "list", "packages", "-U", id])
            guard generation == session, selectedSerial == serial, selectedPackage == id else { return }
            guard let updated = AndroidPackage.parse(output).first(where: { $0.id == id }) else {
                stop(); errorMessage = "当前应用已卸载或暂时不可用，已保留日志。安装完成后请刷新应用列表。"
                return
            }
            if updated.uid != capturedUID {
                if let index = packages.firstIndex(where: { $0.id == id }) { packages[index] = updated }
                else { packages.append(updated) }
                start()
            }
        } catch {
            // A transient metadata failure must not interrupt a healthy log stream.
        }
    }

    func selectDevice(_ serial: String) async {
        guard selectedSerial != serial || packages.isEmpty else { return }
        if selectedSerial != serial { activateDevice(serial) }
        refreshFavoriteMetadata(readDevice: false)
        defaults.set(serial, forKey: "selectedSerial")
        await refreshPackages()
    }

    private func saveSession() {
        rememberFilter()
        appSessions[sessionKey] = AppSession(buffer: buffer, errors: errorCount, pendingLoss: pendingLoss,
                                           filter: currentFilter, selectedLog: selectedLog, follow: follow)
        devicePackages[selectedSerial] = selectedPackage
    }

    private func restoreSession() {
        let saved = appSessions.removeValue(forKey: sessionKey)
        filterTask?.cancel(); restoringSession = true
        buffer = saved?.buffer ?? LogBuffer(); errorCount = saved?.errors ?? 0; pendingLoss = saved?.pendingLoss ?? 0
        let filter = saved?.filter ?? SavedLogFilter(query: "", tag: "", regex: false, minimum: 0)
        query = filter.query; tag = filter.tag; regex = filter.regex; minimum = LogLevel.allCases[filter.minimum]
        paused = false; pausedSnapshot = []; receivedWhilePaused = 0; follow = saved?.follow ?? true
        totalCount = buffer.entries.count; evicted = buffer.evicted + pendingLoss
        selectedLog = saved?.selectedLog; errorMessage = nil
        listFind.close(); detailFind.close(); restoringSession = false; applyFilters()
        defaults.set(selectedPackage, forKey: "selectedPackage")
    }

    /// Sessions are scoped to both the device and the selected application (including all apps).
    func activateDevice(_ serial: String) {
        guard selectedSerial != serial else { return }
        stop(); saveSession()
        selectedSerial = serial; selectedPackage = devicePackages[serial] ?? ""
        packages = []; loadingApps = false; packageRequest = UUID()
        restoreSession()
    }

    func refreshPackages() async {
        guard let path = adbPath, device?.ready == true else { return }
        let serial = selectedSerial, request = UUID(); packageRequest = request; loadingApps = true
        var args = ["-s", serial, "shell", "cmd", "package", "list", "packages", "-U"]
        if !includeSystem { args.append("-3") }
        do {
            let output = try await ADB.run(path: path, arguments: args)
            guard selectedSerial == serial, packageRequest == request, device?.ready == true else { return }
            packages = AndroidPackage.parse(output); loadingApps = false
            if !selectedPackage.isEmpty && !packages.contains(where: { $0.id == selectedPackage }) {
                stop(); errorMessage = "当前应用未在设备应用列表中找到，已保留日志。请检查安装状态或开启「显示系统应用」后刷新。"
            } else if !running || capturedUID != package?.uid {
                start()
            }
            refreshFavoriteMetadata()
        } catch {
            guard selectedSerial == serial, packageRequest == request else { return }
            loadingApps = false; errorMessage = error.localizedDescription
        }
    }

    func selectPackage(_ id: String) {
        guard selectedPackage != id else { return }
        stop(); saveSession(); selectedPackage = id
        restoreSession(); start()
    }

    func start() {
        guard canStart, let path = adbPath else { return }
        stop(); errorMessage = nil; generation = UUID(); let session = generation
        inbox.reset(session)
        do {
            try stream.start(path: path, serial: selectedSerial, uid: package?.uid, onLines: { [inbox] lines in
                inbox.receive(lines, session: session)
            }, onExit: { [weak self] reason in
                Task { @MainActor in
                    guard let self = self, self.generation == session else { return }
                    self.flush(limit: nil); self.running = false; self.errorMessage = reason
                }
            })
            capturedUID = package?.uid; running = true
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() { stream.stop(); flush(limit: nil); running = false; generation = UUID(); inbox.reset(generation) }
    func togglePause() {
        paused.toggle()
        if paused { pausedSnapshot = buffer.entries }
        else { pausedSnapshot = []; receivedWhilePaused = 0; applyFilters() }
    }
    var isFollowing: Bool { follow && !paused }
    func toggleFollow() {
        if paused { togglePause(); follow = true }
        else { follow.toggle() }
    }
    func clear() {
        _ = inbox.drain(); buffer.clear(); visible = []; pausedSnapshot = []; selectedLog = nil
        totalCount = 0; errorCount = 0; evicted = 0; pendingLoss = 0; receivedWhilePaused = 0; revision += 1; rebuildListFind()
    }
    private func flush(limit: Int? = 1_000) {
        let (batch, lost) = inbox.drain(limit: limit); guard !batch.isEmpty || lost > 0 else { return }
        ingest(batch, lost: lost)
    }
    func ingest(_ batch: [LogEntry], lost: Int = 0) {
        let changedFrom = buffer.append(batch)
        pendingLoss += lost; totalCount = buffer.entries.count; evicted = buffer.evicted + pendingLoss
        errorCount += batch.reduce(0) { $0 + ($1.level.rank >= LogLevel.error.rank ? 1 : 0) }
        if paused { receivedWhilePaused += batch.count } else { applyFilters(changedFrom: changedFrom) }
    }
    private func scheduleFilter() {
        guard !restoringSession else { return }
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }; self?.applyFilters()
        }
    }
    private func applyFilters(changedFrom: Int? = nil) {
        guard !restoringSession else { return }
        filterTask?.cancel()
        do {
            let source = paused ? pausedSnapshot : buffer.entries
            let incremental = !paused && appliedFilter == currentFilter && filterError == nil && (changedFrom ?? 0) > 0
            let start = incremental ? min(changedFrom ?? 0, source.count) : 0
            let changed = source.dropFirst(start)
            if let selected = selectedLog,
               let refreshed = changed.first(where: { $0.id == selected.id || $0.sourceIDs.contains(selected.id) }), refreshed != selected {
                selectedLog = refreshed
            }
            let matches = try LogFilter(minimum: minimum, query: query, tag: tag, regex: regex).apply(to: Array(changed))
            appliedFilter = currentFilter; filterError = nil
            if incremental {
                guard let firstID = changed.first?.id else { return }
                var keep = visible.count
                while keep > 0 && visible[keep - 1].id >= firstID { keep -= 1 }
                guard keep != visible.count || !matches.isEmpty else { return }
                visible.removeLast(visible.count - keep); visible.append(contentsOf: matches)
                listFind.replaceLogSuffix(from: firstID, entries: matches)
            } else {
                visible = matches; rebuildListFind()
            }
            revision += 1
        } catch {
            visible = []; revision += 1; filterError = "正则表达式无效：" + error.localizedDescription
            listFind.replaceMatches([])
        }
    }
    func copyDetail(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        notice = "已复制日志详情"
    }
    func export() {
        let panel = NSSavePanel(); panel.title = "导出当前筛选的日志"
        panel.allowedContentTypes = [.plainText]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "logcat-" + formatter.string(from: Date()) + ".log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let header = "# Logcat Mini | device=\(selectedSerial) | package=\(selectedPackage.isEmpty ? "all" : selectedPackage)\n"
            try (header + visible.map(\.fullText).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出 \(visible.count) 条日志"
        } catch { errorMessage = error.localizedDescription }
    }
    func chooseADB() {
        let panel = NSOpenPanel(); panel.title = "选择 Android SDK 的 adb 可执行文件"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { errorMessage = "请选择可执行的 adb 文件。"; return }
        stop(); adbPath = url.path; packages = []; defaults.set(url.path, forKey: "adbPath")
        refreshFavoriteMetadata(readDevice: false)
        errorMessage = nil; Task { await refreshDevices() }
    }
}
