import AppKit

enum ScreenshotClipboard {
    /// Supply image representations, never a filename or file URL, for chat paste targets.
    @MainActor static func copy(_ png: Data, to pasteboard: NSPasteboard = .general) throws {
        guard let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              let tiff = bitmap.tiffRepresentation else {
            throw NSError(domain: "ScreenshotClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "截图文件无法解码为图片。"])
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png); item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw NSError(domain: "ScreenshotClipboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法写入剪贴板，请重试。"])
        }
    }
    @MainActor static func copyFile(_ url: URL, to pasteboard: NSPasteboard = .general) throws {
        try copy(Data(contentsOf: url), to: pasteboard)
    }
}
