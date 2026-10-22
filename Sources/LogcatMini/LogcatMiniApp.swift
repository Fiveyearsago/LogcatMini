import SwiftUI
import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: LogViewModel?
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
            let inLogs = event.window?.title == "Logcat Mini"
            if event.window?.title == "模拟接口请求", event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               self?.replay?.responseFullscreen == true {
                self?.replay?.responseFullscreen = false; return nil
            }
            if inLogs, !(event.window?.firstResponder is MirrorSurfaceView), event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if self?.model?.closeFind() == true { return nil }
                if self?.model?.inspectorFullscreen == true { self?.model?.inspectorFullscreen = false; return nil }
                if self?.model?.logFullscreen == true { self?.model?.logFullscreen = false; return nil }
            }
            guard let appearance = self?.appearance,
                  event.modifierFlags.intersection([.command, .control, .option]) == .command else { return event }
            let key = event.charactersIgnoringModifiers ?? ""
            switch key {
            case "f": if inLogs && !event.modifierFlags.contains(.shift) { self?.model?.toggleFind(); return nil }; return event
            case "j": if inLogs && !event.modifierFlags.contains(.shift) { self?.model?.toggleDetailFormatting(); return nil }; return event
            case "g": if inLogs { self?.model?.currentFind.move(event.modifierFlags.contains(.shift) ? -1 : 1); return nil }; return event
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
        guard media.recording || media.saving || media.takingScreenshot || model.mirror.hasPendingSessions || model.builds.busy || model.builds.detecting else { return .terminateNow }
        Task {
            let allowed = await media.finishBeforeQuit()
            if allowed { await model.builds.finishBeforeQuit(); await model.mirror.finishBeforeQuit() }
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor = keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        model?.shutdown()
    }
}

@main struct LogcatMiniApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = LogViewModel()
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var replay = RequestReplayStore()
    @StateObject private var sDecrypt = LogSDecryptionStore()
    var body: some Scene {
        WindowGroup("Logcat Mini") {
            ContentView(model: model, appearance: appearance, replay: replay, sDecrypt: sDecrypt)
                .preferredColorScheme(appearance.theme.scheme)
                .frame(minWidth: 1040, minHeight: 640)
                .onAppear { delegate.model = model; delegate.appearance = appearance; delegate.replay = replay; model.begin() }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenAppWindowButton(title: "设置…", id: "settings").appShortcut(.settings)
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button(model.logFullscreen ? "恢复菜单" : "日志全屏", action: model.toggleLogFullscreen)
                    .appShortcut(.listFullscreen)
                Button(model.inspectorFullscreen ? "返回日志列表" : "日志详情全屏") { model.inspectorFullscreen.toggle() }
                    .appShortcut(.detailFullscreen).disabled(model.selectedLog == nil)
                Button(model.mirrorShown ? "收起手机投屏" : "手机投屏", action: model.toggleMirror)
                Menu("显示列") { LogColumnMenuItems(appearance: appearance) }
                Divider()
                Button("放大文字", action: appearance.increase).keyboardShortcut("+", modifiers: [.command]).disabled(!appearance.canIncrease)
                Button("缩小文字", action: appearance.decrease).keyboardShortcut("-", modifiers: [.command]).disabled(!appearance.canDecrease)
                Button("恢复默认字号", action: appearance.resetFontSize).keyboardShortcut("0", modifiers: [.command])
                Menu("主题") {
                    ThemeMenuItems(appearance: appearance)
                }
            }
            CommandGroup(after: .textEditing) {
                Button(model.detailFormatted ? "还原日志格式" : "格式化日志", action: model.toggleDetailFormatting)
                    .appShortcut(.format).disabled(!model.canFormatDetail || model.selectedLog == nil)
                Button("显示 / 隐藏当前查找") { model.toggleFind() }.appShortcut(.find)
                Button("查找下一处") { model.currentFind.move(1) }.appShortcut(.next)
                Button("查找上一处") { model.currentFind.move(-1) }.appShortcut(.previous)
                Button("在日志列表中查找…") { model.inspectorFullscreen = false; model.openFind(.list) }
                Button("在日志详情中查找…") { model.openFind(.detail) }.disabled(model.selectedLog == nil)
            }
            CommandGroup(replacing: .newItem) {
                OpenAppWindowButton(title: "模拟接口请求与历史…", id: "request-replay")
                OpenAppWindowButton(title: "s 串解密…", id: "s-decryption")
                OpenAppWindowButton(title: "本地项目与构建输出…", id: "local-build")
                Divider()
                MediaCaptureCommands(model: model, media: model.media)
                OpenAppWindowButton(title: "截图与录屏历史", id: "media-history").appShortcut(.history)
                Divider()
                Button("导出筛选日志…", action: model.export).appShortcut(.export)
                Button("清空当前视图", action: model.clear).appShortcut(.clear)
            }
            CommandMenu("日志") {
                Button(model.running ? "停止采集" : "开始采集") { model.running ? model.stop() : model.start() }
                    .appShortcut(.capture)
                Button(model.paused ? "恢复滚动" : "暂停滚动", action: model.togglePause)
                    .appShortcut(.pause).disabled(!model.running && !model.paused)
                Button(model.isFollowing ? "停止跟随最新日志" : "跟随最新日志", action: model.toggleFollow).appShortcut(.follow)
                Divider()
                Button("刷新设备与应用") { Task { await model.refreshDevices(); await model.refreshPackages() } }
                Button("选择 ADB…", action: model.chooseADB)
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 Logcat Mini") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Logcat Mini", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本", .credits: NSAttributedString(string: "轻量 Android 日志客户端\n原生 macOS · 本地采集 · 无需登录")])
                }
            }
        }
        Window("设置", id: "settings") {
            AppSettingsView(model: model, appearance: appearance, library: model.media.library)
                .preferredColorScheme(appearance.theme.scheme).frame(minWidth: 600, minHeight: 600)
        }.defaultSize(width: 660, height: 760)
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
    }
}

private struct OpenAppWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button(title) { openWindow(id: id) } }
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
