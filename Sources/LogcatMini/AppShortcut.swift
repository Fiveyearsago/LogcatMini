import SwiftUI

enum AppShortcut: CaseIterable {
    case format, listFullscreen, detailFullscreen, capture, pause, follow, clear, export
    case find, next, previous, screenshot, screenshotCopy, recording, history, settings
    var key: KeyEquivalent {
        switch self {
        case .format: return "j"
        case .listFullscreen, .detailFullscreen, .find: return "f"
        case .capture, .recording: return "r"
        case .pause: return "p"
        case .follow: return "l"
        case .clear: return "k"
        case .export, .screenshot: return "s"
        case .next, .previous: return "g"
        case .screenshotCopy: return "c"
        case .history: return "h"
        case .settings: return ","
        }
    }
    var modifiers: EventModifiers {
        switch self {
        case .listFullscreen, .export, .previous, .screenshotCopy, .recording, .history: return [.command, .shift]
        case .detailFullscreen, .screenshot: return [.command, .option]
        default: return .command
        }
    }
    var label: String {
        (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + "⌘" + String(key.character).uppercased()
    }
}

extension View {
    func appShortcut(_ shortcut: AppShortcut) -> some View { keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers) }
}

struct ShortcutLabel: View {
    let title: String
    let systemImage: String
    let keys: String
    init(_ title: String, systemImage: String, shortcut: AppShortcut) {
        self.title = title; self.systemImage = systemImage; keys = shortcut.label
    }
    init(_ title: String, systemImage: String, keys: String) {
        self.title = title; self.systemImage = systemImage; self.keys = keys
    }
    var body: some View {
        HStack(spacing: 5) {
            Label(title, systemImage: systemImage)
            Text(keys).opacity(0.65)
        }.fixedSize().accessibilityElement(children: .combine)
    }
}
