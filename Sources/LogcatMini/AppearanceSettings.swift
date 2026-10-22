import SwiftUI
import AppKit
import LogcatCore

enum AppTheme: String, CaseIterable, Identifiable {
    case system, mist, paper, nightfall, light, graphite, ocean
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .mist: return "雾白"
        case .nightfall: return "夜航蓝"
        case .light: return "明亮"
        case .paper: return "暖纸"
        case .graphite: return "石墨"
        case .ocean: return "深海"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .paper, .mist: return .light
        case .graphite, .ocean, .nightfall: return .dark
        }
    }
    func palette(for systemScheme: ColorScheme) -> ThemePalette {
        let resolved = self == .system ? (systemScheme == .dark ? AppTheme.graphite : .light) : self
        switch resolved {
        case .mist:
            return ThemePalette(id: resolved.rawValue, dark: false, canvas: 0xF7F9FC, panel: 0xEDF1F7, text: 0x223044, muted: 0x56667D, accent: 0x24787D, field: 0xFFFFFF, line: 0xD8E1ED, chip: 0xE7EDF5,
                logs: LogColors(key: 0x7154A2, string: 0x2E704F, number: 0x9A571B, literal: 0xA14765, url: 0x236D9D, tags: [0x237689, 0x5266A1, 0x7851A0, 0x3D754F, 0x93601F], stripe: 0xF0F4F9, selection: 0xDCEBF3))
        case .nightfall:
            return ThemePalette(id: resolved.rawValue, dark: true, canvas: 0x182330, panel: 0x202F40, text: 0xDCE5EF, muted: 0xA2B2C7, accent: 0x8BBFE8, field: 0x13202D, line: 0x34495C, chip: 0x293C50,
                logs: LogColors(key: 0xBCA5DE, string: 0xAACF95, number: 0xE5B47F, literal: 0xD8A0B8, url: 0x8BCBE3, tags: [0x83C7CC, 0xB5A2D8, 0xA5C991, 0x9DBFE8, 0xD8B292], stripe: 0x1C2938, selection: 0x293D50))
        case .light, .system:
            return ThemePalette(id: resolved.rawValue, dark: false, canvas: 0xFAFBFD, panel: 0xEDF1F5, text: 0x202B35, muted: 0x526170, accent: 0x00686C, field: 0xFFFFFF, line: 0xD4DCE4, chip: 0xE9EEF3)
        case .paper:
            return ThemePalette(id: resolved.rawValue, dark: false, canvas: 0xF6F0E5, panel: 0xEAE3D6, text: 0x352F28, muted: 0x655D50, accent: 0x4E7055, field: 0xFFFAF1, line: 0xD8CDBB, chip: 0xE9E0D0,
                logs: LogColors(key: 0x77508C, string: 0x486A35, number: 0x9B541E, literal: 0xA14D5F, url: 0x356F83, tags: [0x3C7050, 0x805324, 0x565C95, 0x39727B, 0x86546B], stripe: 0xF0EADD, selection: 0xE1E6D4))
        case .graphite:
            return ThemePalette(id: resolved.rawValue, dark: true, canvas: 0x20242A, panel: 0x292E36, text: 0xE8EDF3, muted: 0xB0BBC7, accent: 0x8DE0BE, field: 0x181D23, line: 0x414A55, chip: 0x303741)
        case .ocean:
            return ThemePalette(id: resolved.rawValue, dark: true, canvas: 0x152231, panel: 0x1D2D40, text: 0xE4EEF8, muted: 0xACBED1, accent: 0x99C8FF, field: 0x101D2B, line: 0x384D64, chip: 0x25384E)
        }
    }
}

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

struct LogColors {
    let key, string, number, literal, url: UInt32
    let tags: [UInt32]
    let stripe, selection: UInt32
    static let light = LogColors(key: 0x7154A2, string: 0x2E704F, number: 0x9A571B, literal: 0xA14765, url: 0x236D9D, tags: [0x237689, 0x5266A1, 0x7851A0, 0x3D754F, 0x93601F], stripe: 0xF0F4F9, selection: 0xDCEBF3)
    static let dark = LogColors(key: 0xBCA5DE, string: 0xAACF95, number: 0xE5B47F, literal: 0xD8A0B8, url: 0x8BCBE3, tags: [0x83C7CC, 0xB5A2D8, 0xA5C991, 0x9DBFE8, 0xD8B292], stripe: 0x252E39, selection: 0x2D3D4C)
}

struct ThemePalette {
    let id: String
    let dark: Bool
    private let canvasHex, panelHex, textHex, mutedHex, accentHex, fieldHex, lineHex, chipHex: UInt32
    private let logs: LogColors
    init(id: String, dark: Bool, canvas: UInt32, panel: UInt32, text: UInt32, muted: UInt32, accent: UInt32, field: UInt32, line: UInt32, chip: UInt32, logs: LogColors? = nil) {
        self.id = id; self.dark = dark; canvasHex = canvas; panelHex = panel; textHex = text; mutedHex = muted
        accentHex = accent; fieldHex = field; lineHex = line; chipHex = chip
        self.logs = logs ?? (dark ? .dark : .light)
    }
    var nsCanvas: NSColor { rgb(canvasHex) }
    var nsText: NSColor { rgb(textHex) }
    var nsMuted: NSColor { rgb(mutedHex) }
    var nsPanel: NSColor { rgb(panelHex) }
    var nsLine: NSColor { rgb(lineHex) }
    var nsAccent: NSColor { rgb(accentHex) }
    var nsSelection: NSColor { rgb(logs.selection) }
    func rowColor(level: LogLevel, alternate: Bool) -> NSColor {
        if level.rank >= LogLevel.warning.rank {
            let color = levelColor(level)
            return nsCanvas.blended(withFraction: dark ? 0.12 : 0.09, of: color) ?? nsCanvas
        }
        return alternate ? rgb(logs.stripe) : nsCanvas
    }
    func tagColor(_ tag: String) -> NSColor {
        rgb(logs.tags[LogSyntax.tagColorIndex(tag, count: logs.tags.count)])
    }
    func tokenColor(_ kind: LogTokenKind) -> NSColor {
        switch kind {
        case .key: return rgb(logs.key)
        case .string: return rgb(logs.string)
        case .number: return rgb(logs.number)
        case .literal: return rgb(logs.literal)
        case .url: return rgb(logs.url)
        }
    }
    var canvas: Color { Color(nsColor: nsCanvas) }
    var panel: Color { Color(nsColor: rgb(panelHex)) }
    var text: Color { Color(nsColor: nsText) }
    var muted: Color { Color(nsColor: nsMuted) }
    var accent: Color { Color(nsColor: rgb(accentHex)) }
    var field: Color { Color(nsColor: rgb(fieldHex)) }
    var line: Color { Color(nsColor: rgb(lineHex)) }
    var chip: Color { Color(nsColor: rgb(chipHex)) }
    var onAccent: Color { dark ? Color(nsColor: rgb(0x15222B)) : .white }
    var warning: Color { Color(nsColor: levelColor(.warning)) }
    var error: Color { Color(nsColor: levelColor(.error)) }
    func levelColor(_ level: LogLevel) -> NSColor {
        switch level {
        case .verbose: return nsMuted
        case .debug: return rgb(dark ? 0x96DFBB : 0x286445)
        case .info: return rgb(dark ? 0x99C8FF : 0x185AB0)
        case .warning: return rgb(dark ? 0xF1CE86 : 0x805308)
        case .error, .fatal: return rgb(dark ? 0xFF9DA4 : 0xAB2737)
        }
    }
}

final class AppearanceSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published private(set) var columns = LogColumnVisibility()
    static let defaultFontSize: Double = 14
    static let fontRange: ClosedRange<Double> = 10...26
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "appearance.theme") }
    }
    @Published private(set) var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "appearance.fontSize") }
    }
    @Published var formatDetailByDefault: Bool {
        didSet { defaults.set(formatDetailByDefault, forKey: "logs.formatDetailByDefault") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .paper
        let saved = defaults.object(forKey: "appearance.fontSize") as? Double ?? Self.defaultFontSize
        fontSize = saved.isFinite ? min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, saved)) : Self.defaultFontSize
        formatDetailByDefault = defaults.object(forKey: "logs.formatDetailByDefault") as? Bool ?? true
    }
    var canIncrease: Bool { fontSize < Self.fontRange.upperBound }
    var canDecrease: Bool { fontSize > Self.fontRange.lowerBound }
    func setFontSize(_ value: Double) {
        guard value.isFinite else { return }
        fontSize = min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, value.rounded()))
    }
    func increase() { setFontSize(fontSize + 1) }
    func decrease() { setFontSize(fontSize - 1) }
    func resetFontSize() { setFontSize(Self.defaultFontSize) }
    func setColumn(_ column: LogColumn, visible: Bool) { columns.setVisible(column, visible) }
    func resetColumns() { columns.reset() }
    /// Scale interface labels gently so large log text does not crowd the controls.
    func uiSize(_ base: Double) -> CGFloat { CGFloat(max(11, base) + min(4, max(-1, (fontSize - 14) * 0.4))) }
}

struct LogColumnMenuItems: View {
    @ObservedObject var appearance: AppearanceSettings
    var body: some View {
        ForEach(LogColumn.allCases) { column in
            Toggle(column.title, isOn: Binding(
                get: { appearance.columns.contains(column) },
                set: { appearance.setColumn(column, visible: $0) }
            )).disabled(!appearance.columns.canToggle(column))
        }
        Divider()
        Button("恢复默认列", action: appearance.resetColumns)
    }
}

/// Direct menu items avoid SwiftUI wrapping a Picker in another "主题" submenu.
struct ThemeMenuItems: View {
    @ObservedObject var appearance: AppearanceSettings
    var body: some View {
        ForEach(AppTheme.allCases) { theme in
            Button { appearance.theme = theme } label: {
                if appearance.theme == theme { Label(theme.title, systemImage: "checkmark") }
                else { Text(theme.title) }
            }
        }
    }
}
