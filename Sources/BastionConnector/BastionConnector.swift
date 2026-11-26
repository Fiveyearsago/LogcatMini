import AppKit
import ApplicationServices

import WindowsAppCards

@main @MainActor final class BastionConnector: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = BastionConnector()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await Self.connect()
            NSApp.terminate(nil)
        }
    }

    private static func connect() async {
        let args = CommandLine.arguments
        guard args.count == 2, !args[1].isEmpty else { return }
        let name = args[1]
        do {
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                // Granting access is asynchronous. If the user leaves Settings, a later click can retry.
                for _ in 0..<240 {
                    if AXIsProcessTrusted() { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                guard AXIsProcessTrusted() else {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "允许打开已保存的设备"
                    alert.informativeText = "请在系统设置的「隐私与安全性」中，为「Logcat Mini 跳板机连接」开启「设备控制和数据访问」或「辅助功能」。启用后，在 Logcat Mini 重新打开「\(name)」。"
                    alert.addButton(withTitle: "好")
                    alert.addButton(withTitle: "在 Finder 显示连接工具")
                    if alert.runModal() == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    return
                }
            }
            try await WindowsAppCard.open(name)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "打开已保存的跳板机"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
