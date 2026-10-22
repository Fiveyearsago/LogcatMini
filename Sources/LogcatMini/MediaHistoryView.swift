import SwiftUI
import AVKit
import ImageIO

struct MediaHistoryView: View {
    @ObservedObject var library: MediaLibrary
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var selected: CaptureRecord.ID?
    @State private var query = ""
    @State private var type = "all"
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    private var filtered: [CaptureRecord] {
        library.records.filter { record in
            (type == "all" || record.kind.rawValue == type) &&
            (query.isEmpty || [record.filename, record.deviceName, record.serial].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    private var selection: CaptureRecord? { filtered.first { $0.id == selected } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("截图与录屏").font(.title2.bold())
                Text("\(library.records.count) 个文件").foregroundColor(palette.muted)
                Spacer()
                Button { Task { await library.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(library.refreshing)
                Button { openWindow(id: "settings") } label: { Label("保存设置", systemImage: "gearshape") }
            }.padding(20)
            HStack(spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(palette.muted)
                    TextField("搜索文件名或设备", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(9).background(palette.field).cornerRadius(7)
                Picker("类型", selection: $type) {
                    Text("全部").tag("all")
                    ForEach(CaptureKind.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 210)
            }.padding(.horizontal, 20).padding(.bottom, 16)
            if let error = library.error {
                HStack { Text(error).font(.caption); Spacer(); Button("关闭") { library.error = nil } }
                    .padding(12).foregroundColor(palette.error)
            }
            Divider()
            if library.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38)).foregroundColor(palette.accent)
                    Text("还没有截图或录屏").font(.headline)
                    Text("保存后会自动出现在这里。已选文件夹中旧版 Logcat Mini 保存的文件也会收录。")
                        .foregroundColor(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
                    Button("设置保存文件夹") { openWindow(id: "settings") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(filtered) { record in
                            HStack(alignment: .center, spacing: 12) {
                                CaptureThumbnail(record: record, revision: library.refreshGeneration, palette: palette)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.filename).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(record.filename)
                                    Text(record.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundColor(palette.muted)
                                    Text(record.exists ? record.deviceName : "文件已移动或删除").font(.caption).foregroundColor(record.exists ? palette.muted : palette.warning)
                                }
                            }.padding(.vertical, 5).tag(record.id)
                                .contextMenu {
                                    if record.kind == .screenshot {
                                        Button("复制图片") {
                                            do { try ScreenshotClipboard.copyFile(record.url) }
                                            catch { library.error = error.localizedDescription }
                                        }.disabled(!record.exists)
                                    }
                                    Button("打开文件") { library.open(record) }.disabled(!record.exists)
                                    Button("在 Finder 中显示") { library.reveal(record) }.disabled(!record.exists)
                                }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden).frame(minWidth: 300, idealWidth: 380, maxWidth: 480)
                    if let record = selection {
                        CapturePreview(record: record, library: library, palette: palette).id(record.id)
                            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(filtered.isEmpty ? "没有匹配的文件" : "选择文件查看预览")
                            .foregroundColor(palette.muted).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
            .task { await library.refresh(); if selected == nil { selected = filtered.first?.id } }
            .onChange(of: type) { _ in selected = filtered.first?.id }
            .onChange(of: query) { _ in if selection == nil { selected = filtered.first?.id } }
            .onChange(of: library.records.count) { _ in if selected == nil { selected = filtered.first?.id } }
    }
}

private struct CaptureThumbnail: View {
    let record: CaptureRecord
    let revision: Int
    let palette: ThemePalette
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var loaded = false
    private var pixelSize: Int { Int(ceil(100 * displayScale)) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7).fill(palette.field)
            Group {
                if record.exists, let image {
                    Image(decorative: image, scale: displayScale).resizable().scaledToFit().padding(3)
                } else if record.exists && !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: record.exists ? record.kind.symbol : "exclamationmark.triangle")
                        Text(record.exists ? "无法预览" : "文件不可用").font(.system(size: 9))
                    }.foregroundColor(palette.muted)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if record.kind == .recording && image != nil && record.exists {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                    .padding(6).background(Circle().fill(Color.black.opacity(0.7))).padding(4)
            }
        }.frame(width: 80, height: 100)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1))
            .accessibilityElement(children: .ignore).accessibilityLabel(record.kind.title + "缩略图")
            .task(id: "\(revision)-\(pixelSize)") {
                let result = await MediaThumbnailLoader.shared.image(for: record, maxPixelSize: pixelSize)
                guard !Task.isCancelled else { return }
                image = result
                loaded = true
            }
    }
}

private struct CapturePreview: View {
    let record: CaptureRecord
    @ObservedObject var library: MediaLibrary
    let palette: ThemePalette
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loaded = false
    @State private var copyNotice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(record.kind.title, systemImage: record.kind.symbol).font(.headline)
                Spacer()
                Button("打开文件") { library.open(record) }.disabled(!record.exists)
                Button { library.reveal(record) } label: { Label("Finder", systemImage: "folder") }.disabled(!record.exists)
            }
            if record.kind == .screenshot {
                HStack {
                    Button {
                        do { try ScreenshotClipboard.copyFile(record.url); copyNotice = "图片已复制，可粘贴到聊天窗口" }
                        catch { copyNotice = nil; library.error = error.localizedDescription }
                    } label: { ShortcutLabel("复制图片", systemImage: "doc.on.doc", keys: "⌥⌘C") }
                        .keyboardShortcut("c", modifiers: [.command, .option]).disabled(!record.exists)
                    if let copyNotice { Text(copyNotice).font(.caption).foregroundColor(palette.accent) }
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(palette.field)
                if !record.exists { Text("文件已移动或删除，历史记录仍保留").foregroundColor(palette.muted) }
                else if let image { Image(nsImage: image).resizable().scaledToFit().padding(8) }
                else if let player { CaptureVideoPlayer(player: player).cornerRadius(10) }
                else if loaded { Text("无法预览此文件，请尝试打开文件").foregroundColor(palette.muted) }
                else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(record.filename).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
            Text(record.createdAt.formatted(date: .abbreviated, time: .standard) + " · " + record.deviceName + (record.duration.map { " · \($0) 秒" } ?? ""))
                .font(.caption).foregroundColor(palette.muted)
            Text(record.url.path).font(.caption).foregroundColor(palette.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20)
            .task(id: record.id) {
                guard record.exists else { loaded = true; return }
                if record.kind == .recording { player = AVPlayer(url: record.url) }
                else {
                    let url = record.url
                    let cgImage = await Task.detached(priority: .userInitiated) {
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2200
                        ] as CFDictionary)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let cgImage { image = NSImage(cgImage: cgImage, size: .zero) }
                }
                loaded = true
            }
            .onDisappear { player?.pause(); player = nil }
    }
}

/// Use the native player directly; it also provides standard playback and full-screen controls.
private struct CaptureVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline; view.showsFullScreenToggleButton = true; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
