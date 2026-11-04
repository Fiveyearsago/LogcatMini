import SwiftUI
import LogcatCore
import UniformTypeIdentifiers

struct IOSBuildView: View {
    @ObservedObject var ios: IOSLogViewModel
    @ObservedObject var builds: IOSBuildController
    @ObservedObject var appearance: AppearanceSettings
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("iOS 本地项目").font(.title2.bold())
                Spacer()
                Menu("已关联应用") {
                    ForEach(builds.projects) { project in Button(project.bundleID) { builds.edit(project.bundleID); Task { await builds.refreshBranch() } } }
                }.disabled(builds.busy)
            }
            Form {
                HStack {
                    TextField("项目目录", text: $builds.draft.directory)
                    Button("识别") { builds.configureDirectory(URL(fileURLWithPath: builds.draft.directory)) }.disabled(builds.draft.directory.isEmpty)
                    Button("选择…", action: builds.chooseDirectory)
                }
                HStack { Text("分支：\(builds.branch.isEmpty ? "未读取" : builds.branch)").foregroundStyle(.secondary); Button("刷新") { Task { await builds.refreshBranch() } } }
                TextField("Bundle ID", text: $builds.draft.bundleID)
                Picker("项目类型", selection: $builds.draft.kind) { ForEach(IOSBuildProject.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if builds.draft.kind == .flutter {
                    TextField("Flavor（可留空）", text: $builds.draft.flavor)
                    Picker("构建模式", selection: $builds.draft.mode) {
                        Text("debug").tag("debug"); Text("profile · 真机").tag("profile"); Text("release · 真机").tag("release")
                    }
                    DisclosureGroup("高级配置", isExpanded: $advanced) {
                        TextField("Flutter 可执行文件", text: $builds.draft.flutterPath)
                        TextField("入口文件", text: $builds.draft.entrypoint)
                        Text("Dart Defines（每行 KEY=VALUE，保存在本机）").font(.caption)
                        TextEditor(text: $builds.draft.defines).font(.system(size: 12, design: .monospaced)).frame(height: 80).border(.secondary.opacity(0.25))
                    }
                } else {
                    TextField("Workspace / Project 路径", text: $builds.draft.container)
                    TextField("Scheme", text: $builds.draft.scheme)
                    TextField("Configuration", text: $builds.draft.configuration)
                }
            }.disabled(builds.busy)
            Text("目标：\((builds.busy ? builds.target : ios.device)?.title ?? "请先选择 iOS 设备")").font(.callout)
            Text("使用当前目录已保存的源码。真机沿用项目的签名与开发者配置；需要先在 Xcode 完成设备准备。安装不会主动卸载原应用或清理应用数据。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存配置") { _ = builds.save() }.disabled(builds.busy)
                Button("编译并运行") { if builds.save(), let device = ios.device { _ = builds.start(builds.draft, device: device) } }
                    .disabled(builds.busy || ios.device == nil)
                if builds.busy { ProgressView().controlSize(.small); Button("取消", action: builds.cancel) }
                Text(builds.status).foregroundStyle(.secondary)
                Spacer()
                Button("复制输出") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(builds.output, forType: .string) }
                Button("导出输出…", action: builds.exportOutput)
            }
            if let error = builds.error { Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
            ScrollView {
                Text(builds.output.isEmpty ? "构建输出会显示在这里。" : builds.output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).background(.quaternary.opacity(0.3)).frame(maxHeight: .infinity)
        }.padding(20).frame(minWidth: 820, minHeight: 680)
    }
}

struct IOSDeviceToolbar: View {
    @ObservedObject var ios: IOSLogViewModel
    @ObservedObject var media: IOSMediaController
    @ObservedObject var builds: IOSBuildController
    let compact: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(ios.devices) { device in Button(device.title) { Task { await ios.selectDevice(device.id) } } }
                Divider(); Button("刷新设备") { Task { await ios.refreshDevices() } }
                Button("设备信息", action: ios.showDeviceInfo).disabled(ios.device == nil)
                Button("安装并运行 .app…") { if let device = ios.device { builds.chooseApp(device: device); openWindow(id: "ios-build") } }.disabled(builds.busy || ios.device == nil)
            } label: { Label(ios.device?.name ?? "选择设备", systemImage: "iphone").lineLimit(1).frame(maxWidth: 145) }
            Button(action: ios.togglePreview) { action(ios.previewShown ? "收起投屏" : "手机投屏", symbol: "iphone") }.disabled(ios.device == nil)
            ScreenshotControl(takingScreenshot: media.takingScreenshot, canCapture: ios.device != nil, compact: compact,
                              save: { ios.takeScreenshot() }, copy: { ios.takeScreenshot(copyOnly: true) })
            Button(action: ios.toggleRecording) {
                action(media.saving ? "保存录屏…" : media.recording ? "停止录屏 \(media.elapsedText)" : media.canRetry ? "重试保存" : "录屏", symbol: media.recording ? "stop.circle.fill" : "record.circle")
            }.disabled(media.saving || (!media.busy && ios.device == nil)).help(media.recording ? "正在录制：\(media.recordingDevice)；切换设备不改变录制目标" : "录屏 · ⇧⌘R；最长 3 分钟")
            if media.canRetry { Button("取消重试", action: media.dismissRetry) }
            Button { openWindow(id: "media-history") } label: { action("媒体历史", symbol: "photo.stack") }
            if let project = builds.project(for: ios.logs.selectedPackage) {
                Button { if let device = ios.device { _ = builds.start(project, device: device); openWindow(id: "ios-build") } } label: {
                    action(builds.busy ? builds.status : "编译并运行", symbol: "play.fill")
                }.disabled(builds.busy || ios.device == nil)
                if !compact { Text(project.buildLabel).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                Button { configure() } label: { action("关联本地项目", symbol: "folder.badge.gearshape") }
            }
            Button { configure() } label: { Image(systemName: "gearshape") }.help("iOS 本地项目与构建输出")
            if media.lastSaved != nil { Button(action: media.revealSaved) { Image(systemName: "folder") }.help("显示最近保存的文件") }
            Spacer(minLength: 0)
        }.buttonStyle(.borderless).font(.system(size: 11)).lineLimit(1)
    }
    private func configure() {
        if !builds.busy { builds.edit(ios.selectedApp?.id ?? ""); Task { await builds.refreshBranch() } }
        openWindow(id: "ios-build")
    }
    @ViewBuilder private func action(_ title: String, symbol: String) -> some View {
        if compact { Image(systemName: symbol).help(title).accessibilityLabel(title) }
        else { Label(title, systemImage: symbol).fixedSize() }
    }
}

struct IOSPreviewPanel: View {
    @ObservedObject var ios: IOSLogViewModel
    @ObservedObject var preview: IOSPreviewController
    @ObservedObject var media: IOSMediaController
    let palette: ThemePalette
    @Environment(\.openWindow) private var openWindow
    @State private var draggingApp = false
    @State private var inputText = ""
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("手机投屏").font(.headline)
                Spacer()
                Button(action: ios.showDeviceInfo) { Image(systemName: "info.circle") }
                Menu {
                    Button("获取设备剪贴板") { ios.transferClipboard(toDevice: false) }
                    Button("发送 Mac 剪贴板到设备") { ios.transferClipboard(toDevice: true) }
                } label: { Image(systemName: "doc.on.clipboard") }.disabled(ios.clipboardBusy || ios.device == nil).fixedSize()
                Button { ios.takeScreenshot() } label: { Image(systemName: "camera") }.disabled(media.takingScreenshot)
                Button(action: ios.toggleRecording) { Image(systemName: media.recording ? "stop.circle.fill" : "record.circle") }.disabled(media.saving)
                Button { if let device = ios.device { preview.connect(device) } } label: { Image(systemName: "arrow.clockwise") }
                Button(action: ios.togglePreview) { Image(systemName: "xmark") }
            }.buttonStyle(.borderless)
            Text(ios.device?.title ?? "设备已断开").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if preview.image != nil, ios.device?.kind == .simulator { IOSSimulatorSurface(preview: preview) }
                    else if let image = preview.image { Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height) }
                    else if preview.loading { ProgressView().colorScheme(.dark) }
                    else { Text(preview.error ?? "等待设备画面").font(.caption).foregroundColor(.white).padding().textSelection(.enabled) }
                }
            }.overlay { if draggingApp { Text("安装 .app 到当前设备").padding().background(palette.panel).cornerRadius(8) } }
                .onDrop(of: [.fileURL], isTargeted: $draggingApp) { providers in
                    guard providers.count == 1, let device = ios.device, !ios.builds.busy else { return false }
                    providers[0].loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        Task { @MainActor in
                            guard let url else { ios.deviceActionError = "无法读取拖入的 .app 文件。"; return }
                            _ = ios.builds.installExisting(url, device: device); openWindow(id: "ios-build")
                        }
                    }
                    return true
                }
            Text(preview.liveFrames ? "原画 · 点击 / 拖动 / 滚动" : "画面预览约每秒刷新一次").font(.caption).foregroundStyle(.secondary)
            if let error = preview.error, preview.image != nil { Text(error).font(.caption).foregroundColor(palette.warning).textSelection(.enabled) }
            if ios.device?.kind == .simulator {
                if let error = preview.controlError { Text(error).font(.caption).foregroundColor(palette.warning).textSelection(.enabled) }
                HStack {
                    TextField("先点设备输入框，再输入文字", text: $inputText).textFieldStyle(.roundedBorder).onSubmit(sendText)
                    Button("发送", action: sendText).disabled(inputText.isEmpty)
                }.disabled(!preview.controllable)
                Text("点击画面后可直接键盘输入 · 支持中文、⌘V 粘贴").font(.caption).foregroundStyle(.secondary)
                Button("打开 \(preview.hostAppName)", action: preview.openSimulator)
            } else {
                Text("请在 iPhone 上操作；此预览不注入触控或键盘事件。").font(.caption).foregroundStyle(.secondary)
            }
            Button("安装并运行 .app…") {
                if let device = ios.device { ios.builds.chooseApp(device: device); openWindow(id: "ios-build") }
            }.disabled(ios.builds.busy || ios.device == nil)
            Text("也可拖入匹配平台的 .app").font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(palette.panel)
    }
    private func sendText() { if preview.sendText(inputText) { inputText = "" } }
}
