import SwiftUI

/// Shared split control: the main action saves and copies; the menu offers clipboard-only capture.
struct ScreenshotControl: View {
    let takingScreenshot: Bool
    let canCapture: Bool
    var compact = false
    let save: () -> Void
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: save) {
                HStack(spacing: 5) {
                    if takingScreenshot { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "camera") }
                    if !compact { Text(takingScreenshot ? "截图中…" : "截图") }
                }.frame(minWidth: 22, minHeight: 22)
            }.accessibilityLabel(takingScreenshot ? "截图中" : "截图")
                .help("保存截图并复制到剪贴板 · ⌥⌘S")
            Menu {
                Button("保存并复制", action: save)
                Button("仅复制", action: copy)
            } label: { Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 14, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("截图选项").help("仅复制，不保存文件 · ⇧⌘C")
        }.buttonStyle(.borderless).fixedSize().disabled(takingScreenshot || !canCapture)
    }
}
