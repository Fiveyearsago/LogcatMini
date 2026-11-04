import SwiftUI
import LogcatCore

struct IOSLogView: View {
    @ObservedObject var ios: IOSLogViewModel
    @ObservedObject var logs: LogViewModel
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var replay: RequestReplayStore
    @ObservedObject var sDecrypt: LogSDecryptionStore
    @ObservedObject var media: IOSMediaController
    @ObservedObject var builds: IOSBuildController
    @State private var appSearch = ""
    @AppStorage("ios.favoritesExpanded") private var favoritesExpanded = true
    @AppStorage("ios.otherAppsExpanded") private var otherAppsExpanded = true
    @State private var inspectorHeight: CGFloat = 240
    @AppStorage("layout.sidebarWidth") private var sidebarWidth = 274.0
    @AppStorage("layout.iosPreviewWidth") private var previewWidth = 330.0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    private var filterKey: String { "\(logs.selectedSerial)\u{0}\(logs.selectedPackage)\u{0}\(logs.query)\u{0}\(logs.tag)\u{0}\(logs.minimum)\u{0}\(logs.regex)" }
    init(ios: IOSLogViewModel, logs: LogViewModel, appearance: AppearanceSettings, replay: RequestReplayStore, sDecrypt: LogSDecryptionStore) {
        self.ios = ios; self.logs = logs; self.appearance = appearance; self.replay = replay; self.sDecrypt = sDecrypt
        self.media = ios.media; self.builds = ios.builds
    }
    var body: some View {
        GeometryReader { window in
            let side = min(max(240, sidebarWidth), max(240, window.size.width - 720))
            HStack(spacing: 0) {
                if !logs.logFullscreen && !logs.inspectorFullscreen {
                    sidebar.frame(width: side)
                    SidebarDivider(palette: palette) { sidebarWidth = max(240, min(640, side + $0)) }.frame(width: 7)
                }
                VStack(spacing: 0) {
                    toolbar
                    ViewThatFits(in: .horizontal) {
                        IOSDeviceToolbar(ios: ios, media: media, builds: builds, compact: false)
                        IOSDeviceToolbar(ios: ios, media: media, builds: builds, compact: true)
                    }.padding(.horizontal, 18).padding(.bottom, 10)
                    if !logs.inspectorFullscreen {
                        LogFilterControls(model: logs, appearance: appearance, palette: palette).padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    if let message = ios.discoveryNotice { notice(message) }
                    if let message = logs.errorMessage { notice(message, isError: true) { logs.errorMessage = nil } }
                    if let message = logs.filterError { notice(message, isError: true) }
                    if let message = media.error { notice(message, isError: true) { media.error = nil } }
                    if let message = media.notice { notice(message) { media.notice = nil } }
                    if let message = ios.deviceActionError { notice(message, isError: true) { ios.deviceActionError = nil } }
                    HStack(spacing: 0) {
                        logArea
                        if ios.previewShown && !logs.inspectorFullscreen {
                            let width = max(260, min(previewWidth, window.size.width - (logs.logFullscreen ? 440 : side + 447)))
                            SidebarDivider(palette: palette, accessibilityTitle: "调整投屏宽度") { previewWidth = max(260, min(560, width - $0)) }.frame(width: 7)
                            IOSPreviewPanel(ios: ios, preview: ios.preview, media: media, palette: palette).frame(width: width)
                        }
                    }
                    if !logs.inspectorFullscreen { footer }
                }
            }.background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
        }
        .onAppear { ios.previewActive = true; ios.begin(); if ios.previewShown, let device = ios.device { ios.preview.connect(device) } }
        .onDisappear { ios.previewActive = false; logs.rememberFilter(); ios.preview.stop() }
        .sheet(isPresented: $ios.infoShown) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("设备信息").font(.title2.bold()); Spacer(); Button("关闭") { ios.infoShown = false } }
                Text(ios.device?.title ?? "设备已断开").foregroundStyle(.secondary)
                if ios.infoLoading { ProgressView() }
                ScrollView { Text(ios.infoText).font(.system(size: appearance.uiSize(12), design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ios.infoText, forType: .string) }.disabled(ios.infoLoading)
                    Button("刷新", action: ios.showDeviceInfo).disabled(ios.infoLoading)
                }
            }.padding(20).frame(width: 680, height: 560)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Logcat Mini", systemImage: "terminal.fill").font(.system(size: appearance.uiSize(21), weight: .bold)).padding(.top, 12)
            Text("iOS · 真机 / 模拟器").font(.caption).foregroundColor(palette.muted)
            HStack {
                Text("设备").font(.caption.bold()); Spacer()
                Button { Task { await ios.refreshDevices(); await ios.refreshProcesses() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新设备与应用").disabled(ios.refreshing || ios.loadingProcesses)
            }.padding(.top, 16)
            ForEach(ios.devices) { device in
                Button { Task { await ios.selectDevice(device.id) } } label: {
                    HStack {
                        Image(systemName: device.kind == .simulator ? "iphone.gen3" : "iphone").foregroundColor(palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.system(size: appearance.uiSize(12), weight: .semibold))
                            Text(device.kind == .simulator ? "模拟器" : "USB 真机").font(.system(size: appearance.uiSize(10))).foregroundColor(palette.muted)
                        }; Spacer()
                        if logs.selectedSerial == device.id { Circle().fill(palette.accent).frame(width: 6, height: 6) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 7).fill(logs.selectedSerial == device.id ? palette.accent.opacity(0.12) : .clear))
                }.buttonStyle(.plain).help(device.title + " · " + device.udid)
            }
            if ios.devices.isEmpty { Text("连接并信任 iPhone，或启动 Simulator。").font(.caption).foregroundColor(palette.muted) }
            Divider().padding(.vertical, 8)
            HStack { Text("应用").font(.caption.bold()); Spacer(); if ios.loadingProcesses { ProgressView().controlSize(.small) }; Text("\(ios.processes.count)").font(.caption) }
            TextField("搜索名称或 Bundle ID", text: $appSearch).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Button { ios.selectApp(nil) } label: { Label("全部应用", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading).padding(12).background(logs.selectedPackage.isEmpty ? palette.accent.opacity(0.12) : .clear) }.buttonStyle(.plain)
                    DisclosureGroup("★ 收藏夹   \(favoriteApps.count)", isExpanded: $favoritesExpanded) {
                        if favoriteApps.isEmpty { Text("点击应用右侧 ☆ 收藏常用应用").font(.caption).foregroundColor(palette.muted).padding(.vertical, 6) }
                        ForEach(favoriteApps) { appRow($0) }
                    }.padding(.top, 14)
                    DisclosureGroup("其他应用", isExpanded: $otherAppsExpanded) {
                        ForEach(ios.processes.filter { !logs.favorites.contains($0.id) && (ios.includeSystem || !$0.isSystem) && matches($0) }) { appRow($0) }
                    }.padding(.top, 14)
                }
            }
            Toggle("显示系统应用", isOn: $ios.includeSystem).font(.caption).toggleStyle(.checkbox)
            DisclosureGroup("手动指定进程 / PID") {
                HStack {
                    TextField("例如 Runner 或 PID", text: $ios.processInput).textFieldStyle(.roundedBorder).onSubmit { ios.selectProcess(ios.processInput) }
                    Button("应用") { ios.selectProcess(ios.processInput) }
                }.padding(.vertical, 6)
                Text("真机同名进程可用 PID 区分；只显示应用主动输出的系统日志。").font(.caption).foregroundColor(palette.muted)
            }.font(.caption)
            Divider()
            HStack {
                Button { openWindow(id: "settings") } label: { Label("设置", systemImage: "gearshape") }
                Spacer(); Text(ios.device == nil ? "未连接" : "iOS 已连接").font(.caption).foregroundColor(palette.muted)
            }.buttonStyle(.plain)
        }.padding(16).background(palette.panel)
    }
    private var favoriteApps: [IOSLogProcess] { ios.favoriteApps.filter { logs.favorites.contains($0.id) && matches($0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private func matches(_ app: IOSLogProcess) -> Bool { appSearch.isEmpty || app.name.localizedCaseInsensitiveContains(appSearch) || app.id.localizedCaseInsensitiveContains(appSearch) || app.executable.localizedCaseInsensitiveContains(appSearch) }
    private func appRow(_ app: IOSLogProcess) -> some View {
        let installed = ios.processes.contains { $0.id == app.id }
        return HStack(spacing: 8) {
            Button { ios.selectApp(ios.processes.first { $0.id == app.id } ?? app) } label: {
                HStack(spacing: 8) {
                    if let icon = ios.icons[app.id] { Image(nsImage: icon).resizable().scaledToFit().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6)) }
                    else { Image(systemName: "app.dashed").frame(width: 30, height: 30).foregroundColor(palette.muted) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.system(size: appearance.uiSize(12), weight: .semibold)).lineLimit(1)
                        Text(installed ? app.id : "当前设备未安装").font(.system(size: appearance.uiSize(10), design: .monospaced)).foregroundColor(palette.muted).lineLimit(1).truncationMode(.middle)
                    }; Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!installed)
            Button { ios.toggleFavorite(app) } label: { Image(systemName: logs.favorites.contains(app.id) ? "star.fill" : "star").foregroundColor(logs.favorites.contains(app.id) ? palette.accent : palette.muted) }.buttonStyle(.plain).help("收藏 / 取消收藏")
        }.padding(9).background(RoundedRectangle(cornerRadius: 7).fill(logs.selectedPackage == app.id ? palette.accent.opacity(0.14) : .clear))
            .help("\(app.name) · \(app.id) · 进程 \(app.executable)")
            .contextMenu {
                Button("关联本地项目…") { if !builds.busy { builds.edit(app.id) }; openWindow(id: "ios-build") }
                Button("复制 Bundle ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.id, forType: .string) }
            }
    }
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) { logActions(compact: false); logActions(compact: true) }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func logActions(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Text(ios.sessionTitle).font(.system(size: appearance.uiSize(14), weight: .semibold)).lineLimit(1)
            if !compact { Text(logs.running ? "采集中" : "已停止").font(.caption).foregroundColor(palette.accent) }
            Spacer(minLength: 10)
            Button { logs.toggleFind() } label: { action("查找", symbol: "magnifyingglass", compact: compact) }.help("查找 · ⌘F")
            Button(action: logs.toggleFollow) { action(logs.isFollowing ? "跟随最新 · 开" : "跟随最新 · 关", symbol: logs.isFollowing ? "checkmark.circle.fill" : "circle", compact: compact) }
            Button(action: logs.togglePause) { action(logs.paused ? "恢复滚动" : "暂停滚动", symbol: logs.paused ? "play.fill" : "pause.fill", compact: compact) }
            Button(action: ios.clear) { action("清空", symbol: "trash", compact: compact) }
            Menu {
                Button("导出筛选日志…", action: logs.export)
                Button("刷新应用") { Task { await ios.refreshProcesses() } }
                Menu("显示列") { LogColumnMenuItems(appearance: appearance) }
                Button("设备信息", action: ios.showDeviceInfo)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            Button(action: logs.toggleLogFullscreen) { action(logs.logFullscreen ? "恢复侧栏" : "日志全屏", symbol: "arrow.up.left.and.arrow.down.right", compact: compact) }
            Button(action: ios.toggleCapture) { action(logs.running ? "停止采集" : "开始采集", symbol: logs.running ? "stop.fill" : "play.fill", compact: compact) }.disabled(!logs.running && !ios.canStart)
        }.buttonStyle(.borderless).font(.system(size: appearance.uiSize(11)))
    }
    @ViewBuilder private func action(_ title: String, symbol: String, compact: Bool) -> some View {
        if compact { Image(systemName: symbol).help(title).accessibilityLabel(title) }
        else { Label(title, systemImage: symbol).fixedSize() }
    }
    private var footer: some View {
        HStack {
            Text("\(logs.visible.count) 条匹配 / \(logs.totalCount) 条缓存")
            if logs.errorCount > 0 { Text("\(logs.errorCount) 条错误").foregroundColor(palette.warning) }
            if logs.paused { Text("暂停滚动 · 后台仍在采集") }
            Spacer(); Text(logs.notice).lineLimit(1)
        }.font(.system(size: appearance.uiSize(11))).foregroundColor(palette.muted).padding(10)
    }
    private func notice(_ message: String, isError: Bool = false, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.font(.system(size: appearance.uiSize(12))).padding(10).foregroundColor(isError ? palette.warning : palette.muted)
    }
    private var logArea: some View {
        GeometryReader { geometry in
            let height = min(max(150, inspectorHeight), max(150, geometry.size.height - 130))
            VStack(spacing: 0) {
                ListSearchHeader(find: logs.listFind, palette: palette) { logs.activeFindPane = .list }
                    .frame(height: logs.inspectorFullscreen ? 0 : nil).clipped()
                ZStack {
                    LogTable(entries: logs.visible, revision: logs.revision, palette: palette, fontSize: appearance.fontSize,
                             visibleColumns: appearance.columns.visibleColumns, filterKey: filterKey, follow: $logs.follow,
                             selected: $logs.selectedLog, find: logs.listFind, activate: { logs.activeFindPane = .list }, didCopy: {})
                    if logs.visible.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "iphone").font(.system(size: appearance.uiSize(32))).foregroundColor(palette.accent)
                            Text(logs.running ? "正在等待匹配的 iOS 日志" : "选择设备与应用，开始采集")
                            Text("在 App 中操作以产生新日志；没有输出时检查进程名、筛选条件和应用的日志方式。")
                                .font(.system(size: appearance.uiSize(12))).foregroundColor(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                        }.allowsHitTesting(false)
                    }
                }.frame(height: logs.inspectorFullscreen ? 0 : nil).clipped()
                if let entry = logs.selectedLog {
                    InspectorDivider(palette: palette) { delta in inspectorHeight = min(max(150, height + delta), max(150, geometry.size.height - 130)) }
                        .frame(height: logs.inspectorFullscreen ? 0 : 10).clipped()
                    LogInspector(entry: entry, palette: palette, appearance: appearance, fullscreen: $logs.inspectorFullscreen,
                                 find: logs.detailFind, activate: { logs.activeFindPane = .detail }, copy: { _ = logs.copyDetail($0) },
                                 close: { logs.selectedLog = nil }, simulate: {
                                     replay.importLog(entry, context: logs.requestContext(for: entry)); openWindow(id: "request-replay")
                                 }, decryptS: { sDecrypt.importLog(entry); openWindow(id: "s-decryption") },
                                 showFormatted: $logs.detailFormatted, canFormat: $logs.canFormatDetail)
                        .frame(height: logs.inspectorFullscreen ? geometry.size.height : height - 10)
                }
            }
        }
    }
}
