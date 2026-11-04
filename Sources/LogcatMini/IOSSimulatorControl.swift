import AppKit
import SwiftUI
import LogcatCore

/// Uses the exact image rectangle, including letterboxing, in top-left coordinates.
enum IOSSimulatorGeometry {
    static func rect(image: CGSize, bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func point(_ point: CGPoint, image: CGSize, bounds: CGRect, clamp: Bool = false) -> CGPoint? {
        let rect = rect(image: image, bounds: bounds)
        guard !rect.isEmpty, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
}

/// Owns one helper and one immutable simulator target. Writes and shutdown are ordered off the UI thread.
final class IOSSimulatorSession: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let writes = DispatchQueue(label: "LogcatMini.simulator-input")
    private let lock = NSLock()
    private var stopped = false
    var receive: (@Sendable ([String: Any]) -> Void)?
    init(developer: String, udid: String, frames: Bool = true, executable: URL? = nil) throws {
        let candidates = [Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("IOSSimulatorBridge"),
                          URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("IOSSimulatorBridge"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/IOSSimulatorBridge")].compactMap { $0 }
        guard let helper = executable ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw LocalBuildError.message("缺少模拟器控制组件，请重新构建并安装 Logcat Mini。")
        }
        process.executableURL = helper
        process.arguments = [developer, udid] + (frames ? ["--frames"] : [])
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // A helper exiting between isRunning and write must never deliver SIGPIPE to the Mac app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func start() throws {
        try process.run()
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = Data()
            var scanned = 0
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                // Native PNG frames are much larger than thumbnails. Scan only newly received
                // bytes, otherwise repeated full-buffer newline scans become quadratic.
                while let end = buffer.dropFirst(scanned).firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    scanned = 0
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { receive?(event) }
                }
                scanned = buffer.count
                if buffer.count > 64_000_000 {
                    receive?(["event": "error", "message": "模拟器画面数据过大，请重新连接投屏。"])
                    stop(); break
                }
            }
            process.waitUntilExit()
            lock.lock(); let expected = stopped; lock.unlock()
            if !expected { receive?(["event": "closed", "message": "模拟器连接已结束，请重新连接投屏。"] ) }
        }
    }
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
        writes.async { [self] in try? input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }; stopped = true
        writes.async { [self] in
            try? input.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"release\"}\n{\"type\":\"quit\"}\n".utf8))
            try? input.fileHandleForWriting.close()
        }
        let process = process
        // The bridge handles TERM by discarding queued input and releasing the held contact/keys.
        // EOF also wakes an idle stdin reader if the signal landed on the frame thread.
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 7) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    deinit { try? input.fileHandleForWriting.close() }
}

struct IOSSimulatorSurface: NSViewRepresentable {
    @ObservedObject var preview: IOSPreviewController
    func makeNSView(context: Context) -> IOSSimulatorSurfaceView { IOSSimulatorSurfaceView() }
    func updateNSView(_ view: IOSSimulatorSurfaceView, context: Context) {
        if view.deviceID != preview.target?.id || (!preview.controllable && view.enabled) { view.releaseInput() }
        view.preview = preview; view.deviceID = preview.target?.id; view.enabled = preview.controllable
        view.image = preview.image
    }
    static func dismantleNSView(_ view: IOSSimulatorSurfaceView, coordinator: ()) { view.releaseInput(); view.preview = nil }
}

final class IOSSimulatorSurfaceView: NSView, NSTextInputClient {
    weak var preview: IOSPreviewController?
    var deviceID: String?
    var enabled = false
    var image: NSImage? { didSet { needsDisplay = true } }
    private var contact: CGPoint?
    private var marked = NSAttributedString(string: "")
    private var blur: NSObjectProtocol?
    private var scrollEnd: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { enabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("模拟器交互画面")
        setAccessibilityHelp("点击、拖动或滚动操作模拟器；点击输入框后可键盘输入，支持中文和粘贴。")
        blur = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.releaseInput() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { if let blur { NotificationCenter.default.removeObserver(blur) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        if let image {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: IOSSimulatorGeometry.rect(image: image.size, bounds: bounds), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if hasMarkedText() {
            let rect = CGRect(x: 8, y: bounds.height - 32, width: bounds.width - 16, height: 25)
            NSColor.textBackgroundColor.setFill(); rect.fill()
            marked.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 4))
        }
    }
    private func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        guard enabled, let image else { return nil }
        return IOSSimulatorGeometry.point(convert(event.locationInWindow, from: nil), image: image.size, bounds: bounds, clamp: clamp)
    }
    override func mouseDown(with event: NSEvent) {
        guard let point = point(event) else { return }
        releaseInput(); window?.makeFirstResponder(self); contact = point; preview?.touch(phase: 0, at: point)
    }
    override func mouseDragged(with event: NSEvent) {
        guard contact != nil, let point = point(event, clamp: true) else { return }
        contact = point; preview?.touch(phase: 1, at: point)
    }
    override func mouseUp(with event: NSEvent) {
        if let last = contact { preview?.touch(phase: 2, at: point(event, clamp: true) ?? last) }; contact = nil
    }
    func releaseInput() {
        scrollEnd?.cancel(); scrollEnd = nil; contact = nil; preview?.releaseInput()
        unmarkText(); inputContext?.discardMarkedText()
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    override func scrollWheel(with event: NSEvent) {
        guard let origin = point(event) else { return }
        window?.makeFirstResponder(self); scrollEnd?.cancel()
        if contact == nil { contact = origin; preview?.touch(phase: 0, at: origin) }
        guard var next = contact else { return }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let rect = IOSSimulatorGeometry.rect(image: image?.size ?? .zero, bounds: bounds)
        next.x = min(0.98, max(0.02, next.x + event.scrollingDeltaX * multiplier / max(1, rect.width)))
        next.y = min(0.98, max(0.02, next.y + event.scrollingDeltaY * multiplier / max(1, rect.height)))
        contact = next; preview?.touch(phase: 1, at: next)
        let end = DispatchWorkItem { [weak self] in guard let self, let point = contact else { return }; preview?.touch(phase: 2, at: point); contact = nil }
        scrollEnd = end; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: end)
    }
    override func keyDown(with event: NSEvent) {
        guard enabled else { return }
        if shortcut(event) { return }
        interpretKeyEvents([event])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, enabled else { return false }
        return shortcut(event)
    }
    private func shortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if key == "v" { if let text = NSPasteboard.general.string(forType: .string) { preview?.sendText(text) }; return true }
        let usages: [String: Int] = ["a": 4, "c": 6, "x": 27, "z": 29]
        guard let usage = usages[key] else { return false }
        preview?.key(usage, modifiers: event.modifierFlags.contains(.shift) ? [227, 225] : [227]); return true
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText(); if !text.isEmpty { preview?.sendText(text) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? ""); needsDisplay = true
    }
    func unmarkText() { marked = NSAttributedString(string: ""); needsDisplay = true }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(CGRect(x: 8, y: bounds.height - 32, width: 12, height: 25), to: nil)) ?? .zero
    }
    override func doCommand(by selector: Selector) {
        let keys: [String: Int] = ["deleteBackward:": 42, "deleteForward:": 76, "insertNewline:": 40, "insertTab:": 43,
                                    "moveLeft:": 80, "moveRight:": 79, "moveUp:": 82, "moveDown:": 81,
                                    "cancelOperation:": 41, "moveToBeginningOfLine:": 74, "moveToEndOfLine:": 77]
        if let usage = keys[NSStringFromSelector(selector)] { preview?.key(usage) }
    }
}
