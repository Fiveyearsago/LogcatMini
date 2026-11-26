import SwiftUI
import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: LogViewModel?
    weak var displayModel: LogViewModel?
    weak var iosModel: IOSLogViewModel?
    weak var appearance: AppearanceSettings?
    weak var replay: RequestReplayStore?
    private var keyboardMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // A local monitor also accepts the unshifted '=' key and keypad '+'.
        // It is confined to this app; no global shortcut or accessibility permission.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard NSApp.modalWindow == nil else { return event }
            if event.window?.firstResponder is IOSSimulatorSurfaceView { return event }
            let inLogs = event.window?.title == "Logcat Mini" && self?.displayModel != nil
            if event.window?.title == "模拟接口请求", event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               self?.replay?.responseFullscreen == true {
                self?.replay?.responseFullscreen = false; return nil
            }
            if inLogs, !(event.window?.firstResponder is MirrorSurfaceView), event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if self?.displayModel?.closeFind() == true { return nil }
                if self?.displayModel?.inspectorFullscreen == true { self?.displayModel?.inspectorFullscreen = false; return nil }
                if self?.displayModel?.logFullscreen == true { self?.displayModel?.logFullscreen = false; return nil }
            }
            guard let appearance = self?.appearance,
                  event.modifierFlags.intersection([.command, .control, .option]) == .command else { return event }
            let key = event.charactersIgnoringModifiers ?? ""
            switch key {
            case "f": if inLogs && !event.modifierFlags.contains(.shift) { self?.displayModel?.toggleFind(); return nil }; return event
            case "j": if inLogs && !event.modifierFlags.contains(.shift) { self?.displayModel?.toggleDetailFormatting(); return nil }; return event
            case "g": if inLogs { self?.displayModel?.currentFind.move(event.modifierFlags.contains(.shift) ? -1 : 1); return nil }; return event
            case "+", "=": appearance.increase(); return nil
            case "-", "_": appearance.decrease(); return nil
            case "0": appearance.resetFontSize(); return nil
            default: return event
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let media = model.media
        let ios = iosModel
        guard media.recording || media.saving || media.takingScreenshot || model.mirror.hasPendingSessions || model.builds.busy || model.builds.detecting || ios?.media.busy == true || ios?.media.takingScreenshot == true || ios?.builds.busy == true else { return .terminateNow }
        Task {
            let androidAllowed = await media.finishBeforeQuit()
            let iosAllowed = await ios?.media.finishBeforeQuit() ?? true
            let allowed = androidAllowed && iosAllowed
            if allowed { await model.builds.finishBeforeQuit(); await model.mirror.finishBeforeQuit(); await ios?.builds.finishBeforeQuit() }
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor = keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        model?.shutdown()
        iosModel?.shutdown()
    }
}

private enum MainTab {
    case android, ios, bastion
}

@main struct LogcatMiniApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = LogViewModel()
    @StateObject private var ios = IOSLogViewModel()
    @StateObject private var bastion = BastionManager()
    @State private var bastionSheet: BastionSheet?
    @State private var selectedTab: MainTab = .android
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var replay = RequestReplayStore()
    @StateObject private var sDecrypt = LogSDecryptionStore()
    private var showingIOS: Bool { selectedTab == .ios }
    private var logModel: LogViewModel? {
        switch selectedTab {
        case .android: return model
        case .ios: return ios.logs
        case .bastion: return nil
        }
    }
    private func toggleCapture() { if showingIOS { ios.toggleCapture() } else { model.toggleCapture() } }
    private func clearLogs() { if showingIOS { ios.clear() } else { model.clear() } }
    var body: some Scene {
        Window("Logcat Mini", id: "main") {
            VStack(spacing: 0) {
                WorkspaceTabBar(selectedTab: $selectedTab, appearance: appearance)
                switch selectedTab {
                case .android:
                    ContentView(model: model, appearance: appearance, replay: replay, sDecrypt: sDecrypt) { favorite in
                        bastionSheet = .app(favorite, focusAddress: true)
                        selectedTab = .bastion
                    }
                case .ios:
                    IOSLogView(ios: ios, logs: ios.logs, appearance: appearance, replay: replay, sDecrypt: sDecrypt)
                case .bastion:
                    BastionView(manager: bastion, appearance: appearance, sheet: $bastionSheet)
                }
            }
                .preferredColorScheme(appearance.theme.scheme)
                .frame(minWidth: 1040, minHeight: 640)
                .onAppear {
                    ios.media.library = model.media.library
                    delegate.model = model; delegate.displayModel = logModel; delegate.iosModel = ios
                    delegate.appearance = appearance; delegate.replay = replay; model.begin()
                }
                .onChange(of: selectedTab) { _ in delegate.displayModel = logModel; ios.previewActive = showingIOS }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenAppWindowButton(title: "设置…", id: "settings").appShortcut(.settings)
            }
            CommandGroup(after: .toolbar) {
                Divider()
                if let logModel {
                    Button(logModel.logFullscreen ? "恢复菜单" : "日志全屏", action: logModel.toggleLogFullscreen)
                        .appShortcut(.listFullscreen)
                    Button(logModel.inspectorFullscreen ? "返回日志列表" : "日志详情全屏") { logModel.inspectorFullscreen.toggle() }
                        .appShortcut(.detailFullscreen).disabled(logModel.selectedLog == nil)
                    Button((showingIOS ? ios.previewShown : model.mirrorShown) ? "收起手机投屏" : "手机投屏") {
                        if showingIOS { ios.togglePreview() } else { model.toggleMirror() }
                    }
                    Menu("显示列") { LogColumnMenuItems(appearance: appearance) }
                }
                Divider()
                Button("放大文字", action: appearance.increase).keyboardShortcut("+", modifiers: [.command]).disabled(!appearance.canIncrease)
                Button("缩小文字", action: appearance.decrease).keyboardShortcut("-", modifiers: [.command]).disabled(!appearance.canDecrease)
                Button("恢复默认字号", action: appearance.resetFontSize).keyboardShortcut("0", modifiers: [.command])
                Menu("主题") {
                    ThemeMenuItems(appearance: appearance)
                }
            }
            CommandGroup(after: .textEditing) {
                if let logModel {
                    Button(logModel.detailFormatted ? "还原日志格式" : "格式化日志", action: logModel.toggleDetailFormatting)
                        .appShortcut(.format).disabled(!logModel.canFormatDetail || logModel.selectedLog == nil)
                    Button("显示 / 隐藏当前查找") { logModel.toggleFind() }.appShortcut(.find)
                    Button("查找下一处") { logModel.currentFind.move(1) }.appShortcut(.next)
                    Button("查找上一处") { logModel.currentFind.move(-1) }.appShortcut(.previous)
                    Button("在日志列表中查找…") { logModel.inspectorFullscreen = false; logModel.openFind(.list) }
                    Button("在日志详情中查找…") { logModel.openFind(.detail) }.disabled(logModel.selectedLog == nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                OpenAppWindowButton(title: "应用与跳板机", id: "main") { selectedTab = .bastion }
                OpenAppWindowButton(title: "模拟接口请求与历史…", id: "request-replay")
                OpenAppWindowButton(title: "s 串解密…", id: "s-decryption")
                if logModel != nil {
                    OpenAppWindowButton(title: "本地项目与构建输出…", id: showingIOS ? "ios-build" : "local-build")
                    Divider()
                    if showingIOS { IOSMediaCaptureCommands(ios: ios, media: ios.media) }
                    else { MediaCaptureCommands(model: model, media: model.media) }
                }
                OpenAppWindowButton(title: "截图与录屏历史", id: "media-history").appShortcut(.history)
                Divider()
                if let logModel {
                    Button("导出筛选日志…", action: logModel.export).appShortcut(.export)
                    Button("清空当前视图", action: clearLogs).appShortcut(.clear)
                }
            }
            CommandMenu("日志") {
                if let logModel {
                    Button(logModel.running ? "停止采集" : "开始采集", action: toggleCapture)
                        .appShortcut(.capture)
                    Button(logModel.paused ? "恢复滚动" : "暂停滚动", action: logModel.togglePause)
                        .appShortcut(.pause).disabled(!logModel.running && !logModel.paused)
                    Button(logModel.isFollowing ? "停止跟随最新日志" : "跟随最新日志", action: logModel.toggleFollow).appShortcut(.follow)
                    Divider()
                    Button("刷新设备与应用") { Task {
                        if showingIOS { await ios.refreshDevices(); await ios.refreshProcesses() }
                        else { await model.refreshDevices(); await model.refreshPackages() }
                    } }
                    Button("选择 ADB…", action: model.chooseADB).disabled(showingIOS)
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 Logcat Mini") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Logcat Mini",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本",
                        .credits: aboutCredits
                    ])
                }
            }
        }
        Window("设置", id: "settings") {
            AppSettingsView(model: model, appearance: appearance, library: model.media.library)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 600, minHeight: 600)
        }.defaultSize(width: 660, height: 760)
        Window("日志合并规则", id: "log-merge-rules") {
            LogMergeRulesView(settings: model.mergeSettings, appearance: appearance)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 720, minHeight: 560)
        }.defaultSize(width: 820, height: 740)
        Window("截图与录屏", id: "media-history") {
            MediaHistoryView(library: model.media.library, appearance: appearance)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 850, minHeight: 580)
        }.defaultSize(width: 1050, height: 750)
        Window("模拟接口请求", id: "request-replay") {
            RequestReplayView(store: replay, appearance: appearance)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 980, minHeight: 680)
        }.defaultSize(width: 1180, height: 800)
        Window("s 串解密", id: "s-decryption") {
            LogSDecryptionView(store: sDecrypt, appearance: appearance)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 760, minHeight: 600)
        }.defaultSize(width: 900, height: 760)
        Window("本地项目与构建输出", id: "local-build") {
            LocalBuildView(model: model, builds: model.builds, appearance: appearance)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 820, minHeight: 650)
        }.defaultSize(width: 1000, height: 800)
        Window("iOS 本地项目与构建输出", id: "ios-build") {
            IOSBuildView(ios: ios, builds: ios.builds, appearance: appearance)
                .preferredColorScheme(appearance.theme.scheme)
        }.defaultSize(width: 1000, height: 800)
    }

    private var aboutCredits: NSAttributedString {
        let releaseTime: String
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LogcatMiniReleaseDate") as? String,
           let date = ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            releaseTime = formatter.string(from: date)
        } else {
            releaseTime = "未记录（开发构建）"
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(string: "发布时间：\(releaseTime)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        credits.append(NSAttributedString(string: "Android / iOS 日志客户端\n原生 macOS · 本地采集 · 无需登录", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]))
        return credits
    }
}

private struct WorkspaceTabBar: View {
    @Binding var selectedTab: MainTab
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = appearance.theme.palette(for: colorScheme)
        Picker("工作区", selection: $selectedTab) {
            Text("Android").tag(MainTab.android)
            Text("iOS · 真机 / 模拟器").tag(MainTab.ios)
            Text("应用与跳板机").tag(MainTab.bastion)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .foregroundColor(palette.text).tint(palette.accent)
        .background(palette.panel)
        .overlay(alignment: .bottom) { Divider().overlay(palette.line) }
    }
}

private struct OpenAppWindowButton: View {
    let title: String
    let id: String
    var beforeOpen: () -> Void = {}
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) {
            beforeOpen()
            openWindow(id: id)
        }
    }
}

private struct IOSMediaCaptureCommands: View {
    @ObservedObject var ios: IOSLogViewModel
    @ObservedObject var media: IOSMediaController
    var body: some View {
        Button("保存并复制截图") { ios.takeScreenshot() }.appShortcut(.screenshot)
            .disabled(media.takingScreenshot || ios.device == nil)
        Button("截图：仅复制") { ios.takeScreenshot(copyOnly: true) }.appShortcut(.screenshotCopy)
            .disabled(media.takingScreenshot || ios.device == nil)
        Button(media.recording ? "停止录屏" : media.canRetry ? "重试保存录屏" : "开始录屏", action: ios.toggleRecording)
            .appShortcut(.recording).disabled(media.saving || (!media.busy && ios.device == nil))
    }
}

private struct MediaCaptureCommands: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var media: DeviceMediaController
    var body: some View {
        Button("保存并复制截图") { model.takeScreenshot() }.appShortcut(.screenshot)
            .disabled(media.takingScreenshot || model.device?.ready != true || model.adbPath == nil)
        Button("截图：仅复制") { model.takeScreenshot(copy: true) }.appShortcut(.screenshotCopy)
            .disabled(media.takingScreenshot || model.device?.ready != true || model.adbPath == nil)
        Button(media.recording ? "停止录屏" : media.canRetry ? "重试保存录屏" : "开始录屏", action: model.toggleRecording)
            .appShortcut(.recording).disabled(media.saving || (!media.busy && (model.device?.ready != true || model.adbPath == nil)))
    }
}
