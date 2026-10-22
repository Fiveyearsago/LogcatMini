import SwiftUI
import AppKit

struct SidebarDivider: NSViewRepresentable {
    let palette: ThemePalette
    var accessibilityTitle = "调整侧边栏宽度"
    var resize: (CGFloat) -> Void
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) { view.palette = palette; view.setAccessibilityLabel(accessibilityTitle); view.resize = resize; view.needsDisplay = true }
    final class DividerView: NSView {
        var palette: ThemePalette?
        var resize: ((CGFloat) -> Void)?
        private var lastX: CGFloat = 0
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.splitter); setAccessibilityLabel("调整侧边栏宽度")
        }
        required init?(coder: NSCoder) { fatalError() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }
        override func mouseDragged(with event: NSEvent) {
            let x = event.locationInWindow.x; resize?(x - lastX); lastX = x
        }
        override func accessibilityPerformIncrement() -> Bool { resize?(40); return true }
        override func accessibilityPerformDecrement() -> Bool { resize?(-40); return true }
        override func draw(_ dirtyRect: NSRect) {
            palette?.nsPanel.setFill(); bounds.fill()
            palette?.nsLine.setFill(); NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

struct ListSearchHeader: View {
    @ObservedObject var find: LogFindState
    let palette: ThemePalette
    var activate: () -> Void
    var body: some View {
        if find.shown { LogFindBar(find: find, title: "在日志列表中查找", palette: palette, activate: activate) }
    }
}
