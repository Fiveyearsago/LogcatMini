import Foundation
import Darwin

/// Some OEM IMEs ignore physical keyboards. Temporarily use an already-enabled
/// Gboard on those devices. A phone-side lease restores the IME without the Mac.
final class MirrorKeyboardCompatibility: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "LogcatMini.keyboard.lease")
    private let finished = DispatchGroup()
    private var heartbeat: DispatchSourceTimer?
    private var stopping = false // queue only

    init(path: String, serial: String, notice: @escaping @Sendable (String) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: path)
        // adb joins remote arguments; quote the complete script for the remote shell.
        let quoted = "'" + Self.script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        process.arguments = ["-s", serial, "shell", "-T", "sh", "-c", quoted]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [input] in
            try? input.fileHandleForWriting.write(contentsOf: Data("keep\n".utf8))
        }
        heartbeat = timer; timer.resume()
        finished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var pending = Data()
            var active = false
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending.prefix(upTo: newline), as: UTF8.self)
                    pending.removeSubrange(...newline)
                    if line == "READY" { active = true }
                    if line == "MANUAL" || line == "RESTORE_FAILED" { active = false }
                    if let message = Self.notice(for: line) { notice(message) }
                }
            }
            exited.wait()
            let stopped = queue.sync {
                heartbeat?.cancel(); heartbeat = nil; try? input.fileHandleForWriting.close()
                return stopping
            }
            if active && !stopped { notice("兼容隐藏连接已结束，请关闭开关后重试。") }
            finished.leave()
        }
    }

    /// Called on the mirror input queue, never on the UI thread. Serialize an
    /// off/on transition so the old lease restores before a new lease starts.
    func stopAndWait() {
        queue.sync { stopping = true; heartbeat?.cancel(); heartbeat = nil; try? input.fileHandleForWriting.close() }
        if finished.wait(timeout: .now() + 8) == .timedOut, process.isRunning { process.terminate() }
    }

    private static func notice(for status: String) -> String? {
        switch status {
        case "READY": return "当前输入法不支持隐藏，已临时使用 Gboard；取消勾选或关闭投屏后恢复原输入法。"
        case "MISSING": return "当前输入法不支持隐藏软键盘。请在手机上启用 Gboard 后，重新勾选此开关。"
        case "BUSY": return "另一投屏会话正在管理手机输入法，请结束该会话后重试。"
        case "FAILED": return "兼容隐藏未能启用，请关闭开关后重试。"
        case "RESTORE_FAILED": return "原输入法暂未恢复，请重连投屏后重试，或在手机键盘设置中切回。"
        case "MANUAL": return "检测到手动切换输入法，已保留你的选择；如需兼容隐藏，请重新勾选此开关。"
        default: return nil
        }
    }

    // stdin EOF, a lost heartbeat, or a signal all restore on the phone itself.
    // The journal also permits recovery after a killed shell or phone restart.
    // Never enable/install an IME or overwrite a user's later manual selection.
    static let script = #"""
    read -r -t 5 pulse || exit 0
    user=$(am get-current-user)
    case "$user" in ''|*[!0-9]*) echo FAILED; exit 1;; esac
    base="/data/local/tmp/logcat-mini-keyboard-$user"
    gboard=com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME
    current() { settings --user "$user" get secure default_input_method; }
    command -v flock >/dev/null 2>&1 || { echo FAILED; exit 1; }
    exec 9>"$base.lock"
    # Android mksh closes descriptors above 2 in external commands. Duplicate
    # the same open file description to stdin only for flock; fd 9 keeps ownership.
    flock -n 0 <&9 || { echo BUSY; exit 1; }
    original=
    restore() {
        [ -n "$original" ] || return
        if [ "$(current)" = "$gboard" ]; then
            ime set --user "$user" "$original" >/dev/null 2>&1
            if [ "$(current)" != "$original" ]; then echo RESTORE_FAILED; return; fi
        fi
        rm -f "$base.previous"
        original=
    }
    trap 'restore' EXIT
    trap 'exit 0' HUP INT TERM
    if [ -f "$base.previous" ]; then
        original=$(cat "$base.previous")
        case "$original" in com.baidu.input_oppo/*) restore;; *) original=; echo FAILED; exit 1;; esac
        [ -z "$original" ] || exit 1
    fi
    previous=$(current)
    case "$previous" in com.baidu.input_oppo/*) ;; *) exit 0;; esac
    ime list --user "$user" -s | grep -Fxq "$gboard" || { echo MISSING; exit 0; }
    printf '%s\n' "$previous" >"$base.previous" || { echo FAILED; exit 1; }
    original=$previous
    ime set --user "$user" "$gboard" >/dev/null 2>&1
    [ "$(current)" = "$gboard" ] || { echo FAILED; exit 1; }
    echo READY
    while read -r -t 5 pulse; do
        [ "$pulse" = keep ] || break
        [ "$(current)" = "$gboard" ] || { echo MANUAL; break; }
    done
    """#
}
