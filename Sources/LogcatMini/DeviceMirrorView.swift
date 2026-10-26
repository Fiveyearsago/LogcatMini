import SwiftUI
import AVFoundation
import LogcatCore

struct DeviceMirrorPanel: View {
    @ObservedObject var mirror: DeviceMirrorController
    @ObservedObject var media: DeviceMediaController
    let palette: ThemePalette
    let canCapture: Bool
    let takeScreenshot: () -> Void
    let copyScreenshot: () -> Void
    let toggleRecording: () -> Void
    let reconnect: () -> Void
    let close: () -> Void
    @State private var text = ""
    @State private var textError = false
    @State private var showingDeviceInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundColor(palette.accent)
                Text("手机投屏").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button { showingDeviceInfo = true } label: { Image(systemName: "info.circle") }
                    .disabled(mirror.deviceInfoTarget == nil).help("设备信息与 GAID").accessibilityLabel("设备信息与 GAID")
                    .popover(isPresented: $showingDeviceInfo, arrowEdge: .top) {
                        if let target = mirror.deviceInfoTarget {
                            DeviceInfoView(target: target) { showingDeviceInfo = false }
                                .id(target.serial)
                        }
                    }
                Menu {
                    Button("复制手机所选文字（⌘C）", action: mirror.copySelection)
                    Button("获取手机剪贴板", action: mirror.copyDeviceClipboard)
                } label: { Image(systemName: "doc.on.clipboard") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(!mirror.isStreaming)
                    .help("手机复制的文字会自动同步到 Mac；也可手动获取剪贴板")
                    .accessibilityLabel("手机剪贴板")
                ScreenshotControl(takingScreenshot: media.takingScreenshot, canCapture: canCapture,
                                  compact: true, save: takeScreenshot, copy: copyScreenshot)
                Button(action: toggleRecording) {
                    Group {
                        if media.saving { ProgressView().controlSize(.mini) }
                        else { Image(systemName: media.recording ? "stop.circle.fill" : media.canRetry ? "arrow.clockwise.circle" : "record.circle") }
                    }.frame(width: 22, height: 22)
                }.disabled(media.saving || (!media.busy && !canCapture))
                    .foregroundColor(media.recording || media.saving ? palette.error : palette.text)
                    .help(media.busy ? "\(recordingTitle)：\(media.recordingDevice)；录制目标保持不变" : "录制当前手机画面，保存到录屏目录；最长 3 分钟，无声音")
                    .accessibilityLabel("投屏" + recordingTitle)
                Button(action: reconnect) { Image(systemName: "arrow.clockwise") }.help("重新连接投屏").accessibilityLabel("重新连接投屏")
                Button(action: close) { Image(systemName: "xmark") }.help("关闭投屏，继续采集日志").accessibilityLabel("关闭投屏")
            }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.top, 14)
            HStack(spacing: 5) {
                Circle().fill(mirror.isStreaming ? palette.accent : palette.muted).frame(width: 5, height: 5)
                Text(mirror.deviceName.isEmpty ? "跟随当前设备" : mirror.deviceName + " · " + mirror.serial)
                    .lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 10)).foregroundColor(palette.muted).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
            if media.busy {
                Text("\(media.recording && !media.saving ? "录屏中 · " + media.elapsedText : recordingTitle) · \(media.recordingDevice)")
                    .font(.system(size: 10)).foregroundColor(media.canRetry ? palette.warning : palette.error)
                    .lineLimit(1).truncationMode(.middle).help(media.recordingDevice)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            ZStack {
                Color.black
                MirrorSurface(mirror: mirror)
                    .opacity(mirror.isStreaming ? 1 : 0)
                    .allowsHitTesting(mirror.isStreaming)
                if !mirror.isStreaming {
                    VStack(spacing: 12) {
                        if mirror.state == .connecting {
                            ProgressView().controlSize(.small)
                            Text("正在连接手机…")
                        } else {
                            Image(systemName: "iphone.slash").font(.system(size: 28))
                            Text(status).multilineTextAlignment(.center).lineLimit(8)
                            Button("重连投屏", action: reconnect).buttonStyle(.bordered)
                        }
                    }.font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).padding(20)
                }
                if mirror.draggingAPK {
                    palette.accent.opacity(0.85).allowsHitTesting(false)
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.app").font(.system(size: 32))
                        Text("松开以安装 APK").font(.system(size: 15, weight: .semibold))
                        Text(mirror.deviceName).font(.system(size: 12))
                    }.foregroundColor(.white).allowsHitTesting(false)
                }
            }.clipped()
            APKInstallStatus(installer: mirror.installer, palette: palette)
            HStack(spacing: 0) {
                navigation("返回", symbol: "chevron.left", code: 4)
                navigation("主屏幕", symbol: "circle", code: 3)
                navigation("最近任务", symbol: "square", code: 187)
            }.padding(.vertical, 10).disabled(!mirror.isStreaming)
            Toggle("隐藏手机软键盘", isOn: $mirror.hideSoftKeyboard)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .help("投屏时隐藏手机软键盘，使用下方输入框发送文字。部分一加输入法会临时切换到已启用的 Gboard；关闭开关或投屏后恢复原输入法。")
            if let notice = mirror.keyboardNotice {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice).font(.system(size: 10)).foregroundColor(palette.warning).fixedSize(horizontal: false, vertical: true)
                    if mirror.needsKeyboardSettings {
                        Button("手机键盘设置", action: mirror.openKeyboardSettings).font(.system(size: 11))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }
            HStack(spacing: 6) {
                TextField("输入文字，回车发送", text: $text).textFieldStyle(.roundedBorder).onSubmit(sendText)
                    .accessibilityLabel("发送到手机的文字")
                    .help("回车与点击发送效果相同；中文输入法选词完成后再回车发送。")
                Button("发送", action: sendText).disabled(text.isEmpty)
            }.font(.system(size: 11)).padding(.horizontal, 12).disabled(!mirror.isStreaming)
            Text(textError ? "文字过长，请缩短后发送。" : "回车发送文字 · 拖入 APK 安装到此手机")
                .font(.system(size: 10)).foregroundColor(textError ? palette.warning : palette.muted)
                .padding(.horizontal, 8).padding(.vertical, 10)
                .help("手机复制的文字会自动同步到 Mac。点画面后按 ⌘C 复制手机所选文字，⌘V 粘贴到手机；中文也可在上方输入后发送。发送文字会写入手机剪贴板。")
        }.background(palette.panel)
            .onChange(of: mirror.serial) { _ in text = ""; textError = false; showingDeviceInfo = false }
            .onChange(of: mirror.isStreaming) { streaming in if !streaming { showingDeviceInfo = false } }
    }
    private var status: String {
        if case .failed(let message) = mirror.state { return message }
        return "连接手机后即可在这里操作"
    }
    private var recordingTitle: String {
        if media.saving { return "保存录屏中" }
        if media.recording { return "停止录屏" }
        if media.canRetry { return "重试保存录屏" }
        return "开始录屏"
    }
    private func navigation(_ title: String, symbol: String, code: UInt32) -> some View {
        Button { mirror.key(code) } label: {
            Image(systemName: symbol).font(.system(size: 15)).frame(maxWidth: .infinity).frame(height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel("手机" + title)
    }
    private func sendText() {
        guard !text.isEmpty else { return }
        textError = !mirror.sendText(text)
        if !textError { text = "" }
    }
}

private struct APKInstallStatus: View {
    @ObservedObject var installer: DeviceAPKInstaller
    let palette: ThemePalette
    var body: some View {
        if let message = installer.message {
            HStack(alignment: .top, spacing: 8) {
                if installer.isInstalling { ProgressView().controlSize(.small) }
                else { Image(systemName: installer.failed ? "exclamationmark.circle" : "checkmark.circle") }
                Text(message).font(.system(size: 11)).lineLimit(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).help(message)
                if !installer.isInstalling {
                    Button(action: installer.dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭安装结果")
                }
            }.foregroundColor(installer.failed ? palette.warning : palette.accent).padding(10)
        }
    }
}

private struct MirrorSurface: NSViewRepresentable {
    let mirror: DeviceMirrorController
    func makeNSView(context: Context) -> MirrorSurfaceView {
        let view = MirrorSurfaceView()
        view.mirror = mirror
        mirror.frames.display = { [weak view] pixel in view?.display(pixel) }
        view.display(mirror.frames.latest)
        return view
    }
    func updateNSView(_ view: MirrorSurfaceView, context: Context) { view.mirror = mirror }
    static func dismantleNSView(_ view: MirrorSurfaceView, coordinator: ()) { view.cancelTouch(); view.mirror = nil }
}

final class MirrorSurfaceView: NSView {
    weak var mirror: DeviceMirrorController?
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var videoSize: CGSize = .zero
    private var touchPoint: CGPoint?
    private var touchSize: CGSize = .zero
    private var resignObserver: NSObjectProtocol?
    private var dropTarget: APKInstallTarget?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("手机投屏画面"); setAccessibilityHelp("点击或拖动操作手机，息屏时点击画面或黑边可唤醒，滚轮滑动，右键返回。Command C 复制手机所选文字，Command V 粘贴到手机。手机复制的文字自动同步到 Mac。拖入一个 APK 安装到当前手机。")
        registerForDraggedTypes([.fileURL])
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelTouch() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit()
    }

    private func apkURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget = mirror?.apkTarget
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = dropTarget != nil && mirror?.apkTarget == dropTarget && DeviceAPKInstaller.accepts(apkURLs(sender))
        mirror?.draggingAPK = accepted
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = nil; mirror?.draggingAPK = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropTarget = nil; mirror?.draggingAPK = false }
        let urls = apkURLs(sender)
        guard let dropTarget, DeviceAPKInstaller.accepts(urls) else { return false }
        return mirror?.installAPK(urls[0], target: dropTarget) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropTarget = nil; mirror?.draggingAPK = false }

    func display(_ pixel: CVPixelBuffer?) {
        guard let pixel else {
            cancelTouch(); videoSize = .zero; videoLayer.flushAndRemoveImage(); return
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        if size != videoSize { cancelTouch(); videoSize = size; videoLayer.flushAndRemoveImage() }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if videoLayer.status == .failed { videoLayer.flush() }
        if videoLayer.isReadyForMoreMediaData { videoLayer.enqueue(sample) }
    }

    private func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        MirrorProtocol.devicePoint(convert(event.locationInWindow, from: nil), in: bounds, video: videoSize, clamp: clamp)
    }
    override func mouseDown(with event: NSEvent) {
        guard let mirror, mirror.isStreaming else { return }
        window?.makeFirstResponder(self)
        // Wake even when the click falls in the aspect-fit black border. The
        // serial input queue sends this before touch-down, without ADB polling.
        mirror.wakeUp()
        guard let point = point(event) else { return }
        touchSize = videoSize; touchPoint = point
        mirror.send(MirrorProtocol.touch(action: 0, point: point, size: touchSize))
    }
    override func mouseDragged(with event: NSEvent) {
        guard touchPoint != nil, let point = point(event, clamp: true) else { return }
        touchPoint = point; mirror?.send(MirrorProtocol.touch(action: 2, point: point, size: touchSize))
    }
    override func mouseUp(with event: NSEvent) {
        guard touchPoint != nil, let point = point(event, clamp: true) else { return }
        mirror?.send(MirrorProtocol.touch(action: 1, point: point, size: touchSize)); touchPoint = nil
    }
    func cancelTouch() {
        if let point = touchPoint { mirror?.send(MirrorProtocol.touch(action: 3, point: point, size: touchSize)) }
        touchPoint = nil
    }
    override func resignFirstResponder() -> Bool { cancelTouch(); return super.resignFirstResponder() }
    override func rightMouseDown(with event: NSEvent) { if point(event) != nil { mirror?.key(4) } }
    override func scrollWheel(with event: NSEvent) {
        guard let point = point(event) else { return }
        let divisor = event.hasPreciseScrollingDeltas ? 40.0 : 1.0
        mirror?.send(MirrorProtocol.scroll(point: point, size: videoSize,
                                          horizontal: -event.scrollingDeltaX / divisor, vertical: event.scrollingDeltaY / divisor))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "c" {
            mirror?.copySelection()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            if let text = NSPasteboard.general.string(forType: .string) { mirror?.sendText(text) }
            return true
        }
        return false
    }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { super.keyDown(with: event); return }
        let keys: [UInt16: UInt32] = [36: 66, 76: 66, 51: 67, 117: 112, 48: 61, 53: 4, 123: 21, 124: 22, 125: 20, 126: 19]
        if let code = keys[event.keyCode] { mirror?.key(code) }
        else if let characters = event.characters, !characters.isEmpty { mirror?.sendText(characters, paste: false) }
    }
}
