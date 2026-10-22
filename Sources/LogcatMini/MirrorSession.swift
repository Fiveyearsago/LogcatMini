import Foundation
import CoreVideo
import LogcatCore
import Darwin

/// Owns only this mirror's adb child, random socket and forward. Never stops the adb server.
final class MirrorSession: @unchecked Sendable {
    let serial: String
    private let path: String
    private let server: URL
    private let lock = NSLock()
    private var cancelled = false
    private var child: Process?
    private var video: MirrorSocket?
    private var control: MirrorSocket?
    private var diagnostic = Data()
    private var worker: Task<Void, Never>?
    private var finished = false
    let keyboardName = "Logcat Mini Keyboard " + String(UUID().uuidString.prefix(8))
    // Accessed only by inputQueue. UHID descriptors are also removed by the server on disconnect.
    private var keyboardCreated = false
    private var keyboardCompatibility: MirrorKeyboardCompatibility?
    private let inputQueue = DispatchQueue(label: "LogcatMini.mirror.input", qos: .userInteractive)
    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    var onEnd: (String) -> Void = { _ in }
    var onKeyboardNotice: @Sendable (String) -> Void = { _ in }

    init(path: String, serial: String, server: URL) { self.path = path; self.serial = serial; self.server = server }

    func start() { worker = Task.detached(priority: .userInitiated) { await self.run() } }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func waitUntilFinished() async { await worker?.value }

    func stop() {
        lock.lock(); cancelled = true
        let child = child, video = video, control = control
        lock.unlock()
        video?.shutdown(); control?.shutdown()
        if let child, child.isRunning { child.terminate() }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func checkCancellation() throws { if isCancelled { throw CancellationError() } }

    func send(_ data: Data) {
        inputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let socket = self.cancelled ? nil : self.control; self.lock.unlock()
            do { try socket?.write(data) }
            catch { self.stop(); self.onEnd("手机控制连接已断开，请重新连接投屏。") }
        }
    }

    func setHideSoftKeyboard(_ hidden: Bool) {
        inputQueue.async { [weak self] in
            guard let self, self.keyboardCreated != hidden else { return }
            self.lock.lock(); let socket = self.cancelled ? nil : self.control; self.lock.unlock()
            guard let socket else { return }
            do {
                try socket.write(hidden ? MirrorProtocol.keyboardCreate(name: self.keyboardName) : MirrorProtocol.keyboardDestroy)
                self.keyboardCreated = hidden
                if hidden {
                    do {
                        self.keyboardCompatibility = try MirrorKeyboardCompatibility(path: self.path, serial: self.serial, notice: self.onKeyboardNotice)
                    } catch { self.onKeyboardNotice("兼容隐藏未能启用，请关闭开关后重试。") }
                } else {
                    self.keyboardCompatibility?.stopAndWait(); self.keyboardCompatibility = nil
                }
            } catch {
                self.stop(); self.onEnd("手机键盘控制连接已断开，请重新连接投屏。")
            }
        }
    }

    private func run() async {
        // A private copy avoids racing the existing recorder's /data/local/tmp/scrcpy-server.jar.
        let identifier = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        let remote = "/data/local/tmp/logcat-mini-mirror-\(identifier).jar"
        var port: String?
        var failure: String?
        do {
            try checkCancellation()
            _ = try await ADB.run(path: path, arguments: ["-s", serial, "push", server.path, remote], timeout: 15)
            try checkCancellation()
            let value = try await ADB.run(path: path, arguments: ["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_" + identifier])
            guard let number = UInt16(value), number > 0 else { throw MirrorError.message("无法创建投屏连接：\(value)") }
            port = value
            try checkCancellation()
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-s", serial, "shell", "CLASSPATH=" + remote, "app_process", "/", "com.genymobile.scrcpy.Server",
                                 MirrorProtocol.serverVersion, "scid=" + identifier, "log_level=warn", "audio=false", "control=true",
                                 "tunnel_forward=true", "video_codec=h264", "max_size=1280", "max_fps=30", "video_bit_rate=4000000",
                                 "clipboard_autosync=false", "power_on=true", "cleanup=false"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = pipe
            // Atomic with stop: a cancelled startup must never launch a late child.
            try launch(process)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    self?.appendDiagnostic(data)
                }
            }
            var first: MirrorSocket?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                try checkCancellation()
                do {
                    let socket = try MirrorSocket(port: number)
                    try register(socket, video: true)
                    guard try socket.read(count: 1) == Data([0]) else { throw MirrorError.message("投屏握手失败。") }
                    first = socket; break
                } catch {
                    try checkCancellation()
                    if !process.isRunning { throw MirrorError.message("手机投屏服务未能启动。") }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard let first else { throw MirrorError.message("投屏连接超时，请检查 USB 调试授权后重试。") }
            let input = try MirrorSocket(port: number)
            try register(input, video: false)
            input.setReadTimeout(seconds: 0)
            // No clipboard auto-sync. Drain device messages (e.g. paste acknowledgements).
            DispatchQueue.global(qos: .utility).async {
                while (try? input.read(count: 1)) != nil {}
            }
            _ = try first.read(count: 64) // device name; the UI uses the selected ADB device
            guard try first.read(count: 4) == Data("h264".utf8) else { throw MirrorError.message("手机返回了不支持的视频格式。") }
            // A static screen may legitimately produce no encoded frames for minutes.
            // EOF or stop()/shutdown(), rather than inactivity, ends the connection.
            first.setReadTimeout(seconds: 0)
            let decoder = MirrorDecoder { [weak self] frame in
                guard let self, !self.isCancelled else { return }
                self.onFrame(frame)
            }
            while !isCancelled {
                let header = try MirrorProtocol.packetHeader(first.read(count: 12))
                switch header {
                case .session: decoder.reset()
                case .media(let size, let configuration, let time):
                    try decoder.consume(first.read(count: size), configuration: configuration, presentationTime: time)
                }
            }
        } catch {
            if !isCancelled {
                let detail = diagnosticText
                failure = error.localizedDescription + (detail.isEmpty ? "" : "\n" + detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        stop()
        await withCheckedContinuation { continuation in
            inputQueue.async {
                self.keyboardCompatibility?.stopAndWait(); self.keyboardCompatibility = nil
                continuation.resume()
            }
        }
        if let failure { onEnd(failure) }
        // Cleanup is tied to the original serial and unique resources even after a device switch.
        if let port { _ = try? await ADB.run(path: path, arguments: ["-s", serial, "forward", "--remove", "tcp:" + port]) }
        _ = try? await ADB.run(path: path, arguments: ["-s", serial, "shell", "rm", "-f", remote])
        markFinished()
    }

    private func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); child = process
    }
    private func register(_ socket: MirrorSocket, video: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { socket.shutdown(); throw CancellationError() }
        if video { self.video?.shutdown(); self.video = socket }
        else { control = socket }
    }
    private func appendDiagnostic(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        diagnostic.append(data); if diagnostic.count > 4096 { diagnostic = Data(diagnostic.suffix(4096)) }
    }
    private var diagnosticText: String {
        lock.lock(); defer { lock.unlock() }; return String(decoding: diagnostic, as: UTF8.self)
    }
    private func markFinished() { lock.lock(); finished = true; lock.unlock() }
}

private final class MirrorSocket: @unchecked Sendable {
    private var descriptor: Int32
    init(port: UInt16) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MirrorError.message("无法打开本机投屏连接。") }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            Darwin.close(descriptor); descriptor = -1
            throw MirrorError.message("无法连接手机投屏服务。")
        }
    }
    // shutdown wakes blocking reads. Actual close waits until all readers release this object,
    // preventing a stopped session from reading a reused file descriptor.
    func shutdown() { Darwin.shutdown(descriptor, SHUT_RDWR) }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    func setReadTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.recv(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw MirrorError.message("手机投屏连接已断开或超时，请重新连接。") }
                offset += received
            }
        }
        return data
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw MirrorError.message("手机控制连接已断开。") }
                offset += sent
            }
        }
    }
}
