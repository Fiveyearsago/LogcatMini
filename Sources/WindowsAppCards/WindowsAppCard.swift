import AppKit
import ApplicationServices

private struct ConnectionError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor public enum WindowsAppCard {
    public static func open(_ name: String) async throws {
        guard let client = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.rdc.macos") else {
            throw ConnectionError("请先安装 Microsoft Windows App。")
        }
        let app = try await NSWorkspace.shared.openApplication(at: client, configuration: .init())
        app.activate(options: [.activateAllWindows])
        try await openCard(name, app: app)
    }

    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &result) == .success ? result : nil
    }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let p = attribute(node, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(node, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    // The client retains dismissed dialogs in its accessibility tree. Inspect on-screen windows only.
    private static func visibleNodes(_ pid: pid_t) -> [AXUIElement] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let bounds = info.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }.compactMap {
            ($0[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        let windows = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        var nodes = windows.filter { window in
            guard let rect = frame(window) else { return false }
            return bounds.contains { abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2 &&
                abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }
        }
        var index = 0
        while index < nodes.count && nodes.count < 3000 {
            let node = nodes[index]; index += 1
            if attribute(node, kAXRoleAttribute) as? String != kAXTextFieldRole {
                nodes += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
        }
        return nodes
    }

    private static func inDeviceList(_ node: AXUIElement) -> Bool {
        var current = node
        while let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
            current = parent as! AXUIElement
            if let role = attribute(current, kAXRoleAttribute) as? String, [kAXListRole, kAXTableRole, kAXOutlineRole].contains(role) { return true }
        }
        return false
    }

    private static func openCard(_ name: String, app: NSRunningApplication) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let nodes = visibleNodes(app.processIdentifier)
            if nodes.contains(where: { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole ||
                attribute($0, kAXSubroleAttribute) as? String == kAXDialogSubrole || attribute($0, kAXModalAttribute) as? Bool == true }) {
                throw ConnectionError("请先处理 Windows App 当前的登录或证书窗口，再打开跳板机。")
            }
            let cards = nodes.filter { node in
                guard let role = attribute(node, kAXRoleAttribute) as? String,
                      [kAXGroupRole, kAXRowRole, kAXCellRole].contains(role) else { return false }
                return [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute(node, $0) as? String == name } && inDeviceList(node)
            }
            if cards.count > 1 { throw ConnectionError("Windows App 中有多个同名卡片，请手动选择「\(name)」。") }
            if let card = cards.first, app.isActive {
                // Windows App's card AXPress action opens the saved connection, including its credentials.
                let result = AXUIElementPerformAction(card, kAXPressAction as CFString)
                guard result == .success else {
                    throw ConnectionError("Windows App 未能打开「\(name)」卡片，请在客户端重试。")
                }
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw ConnectionError("请在 Windows App 展开设备列表、清空搜索，并让「\(name)」卡片可见后重试。")
    }
}
