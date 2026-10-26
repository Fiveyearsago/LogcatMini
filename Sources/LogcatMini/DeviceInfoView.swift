import SwiftUI

@MainActor final class DeviceInfoModel: ObservableObject {
    @Published private(set) var snapshot: DeviceInfoSnapshot?
    @Published private(set) var advertisingID: AdvertisingIDResult?
    @Published private(set) var advertisingIDReadAt: Date?
    @Published private(set) var needsGAIDRefresh = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let service: DeviceInfoService
    private let serial: String
    private let cache: AdvertisingIDCache
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(target: DeviceInfoTarget, cache: AdvertisingIDCache? = nil, service: DeviceInfoService? = nil) {
        self.service = service ?? DeviceInfoService(target: target)
        self.serial = target.serial; self.cache = cache ?? .shared
        showCachedID()
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; busy = false }

    /// Reopening the popover reuses the saved GAID without querying or reinstalling the helper.
    func load() {
        showCachedID()
        perform { [self] token in
            let value = try await service.readBasics()
            guard generation == token else { return }
            snapshot = value
        }
    }

    func refresh() {
        guard !busy else { return }
        let rereadGAID = advertisingID != nil
        perform { [self] token in
            let value = try await service.readBasics()
            guard generation == token else { return }
            snapshot = value
            if rereadGAID { try await updateGAID(token: token) }
        }
    }
    func readGAID() {
        guard !busy else { return }
        perform { [self] token in
            try await updateGAID(token: token)
        }
    }
    private func updateGAID(token: UUID) async throws {
        do {
            let value = try await service.readAdvertisingID(helper: helperURL())
            guard generation == token, !Task.isCancelled else { return }
            guard cache.store(value, for: serial) != nil else { throw MirrorError.message(value.explanation) }
            showCachedID()
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            cache.markNeedsRefresh(for: serial)
            showCachedID()
            throw error
        }
    }
    private func showCachedID() {
        let entry = cache.entry(for: serial)
        advertisingID = entry?.result
        advertisingIDReadAt = entry?.readAt
        needsGAIDRefresh = entry?.needsRefresh ?? false
    }
    private func helperURL() throws -> URL {
        let resources = Bundle.main.url(forResource: "LogcatMini_LogcatMini", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let helper = resources.url(forResource: "DeviceInfo", withExtension: "apk") else {
            throw MirrorError.message("设备信息助手缺失，请重新构建或安装 Logcat Mini。")
        }
        return helper
    }
    func openSettings(opened: @escaping () -> Void) {
        perform { [self] token in
            try await service.openAdvertisingSettings()
            guard generation == token else { return }
            cache.markNeedsRefresh(for: serial)
            showCachedID()
            opened()
        }
    }
    func waitUntilFinished() async { await task?.value }
    private func perform(_ action: @escaping (UUID) async throws -> Void) {
        guard !busy else { return }
        error = nil; busy = true
        let token = generation
        task = Task {
            do { try await action(token) }
            catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled, generation == token else { return }
            busy = false
        }
    }
}

struct DeviceInfoView: View {
    let target: DeviceInfoTarget
    let dismiss: () -> Void
    @StateObject private var model: DeviceInfoModel
    @State private var copied: String?

    init(target: DeviceInfoTarget, dismiss: @escaping () -> Void) {
        self.target = target; self.dismiss = dismiss
        _model = StateObject(wrappedValue: DeviceInfoModel(target: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("设备信息").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("刷新", action: model.refresh).disabled(model.busy)
                Button("完成", action: dismiss)
            }
            Text(target.name).font(.subheadline).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    row("设备序列号", value: target.serial)
                    if let info = model.snapshot {
                        row("制造商 / 型号", value: [info.properties["ro.product.manufacturer"], info.properties["ro.product.model"]].compactMap { $0 }.joined(separator: " / "))
                        row("Android / API", value: [info.properties["ro.build.version.release"], info.properties["ro.build.version.sdk"]].compactMap { $0 }.joined(separator: " / "))
                        row("系统版本", value: info.properties["ro.build.display.id"])
                        row("安全补丁", value: info.properties["ro.build.version.security_patch"])
                        row("Android ID（ADB）", value: info.androidID)
                        Text("Android ID 为当前用户的 ADB Shell 值；Android 8 起不同签名的应用可能看到不同的值。")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack {
                        Text("GAID · Google 广告 ID").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(model.advertisingID == nil ? "读取 GAID" : "刷新", action: model.readGAID)
                            .disabled(model.busy)
                            .accessibilityLabel(model.advertisingID == nil ? "读取 GAID" : "刷新 GAID")
                    }
                    if let result = model.advertisingID {
                        row("GAID", value: result.gaid)
                        if let limited = result.limitAdTracking { row("限制广告跟踪", value: limited ? "是" : "否") }
                        Text(result.explanation).font(.caption).foregroundColor(.secondary)
                        if let date = model.advertisingIDReadAt {
                            Text("本机缓存 · 上次读取 \(date.formatted(date: .numeric, time: .standard))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if model.needsGAIDRefresh {
                            Text("当前显示上次读取的结果，请刷新以确认手机上的最新 GAID。")
                                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("点击读取当前值。首次读取会在此手机安装「Logcat Mini 设备信息」助手，仅在读取时运行，无联网权限。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button("更换 GAID…") { model.openSettings(opened: dismiss) }.disabled(model.busy)
                    Text("打开手机的广告 ID 设置后，在投屏中确认「重置广告 ID」或「获取新的广告 ID」。完成后重新打开此面板并刷新；不能指定自定义 GAID。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = model.error {
                        Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    // macOS overlay scrollers sit over the content; keep controls outside their track.
                    .padding(.trailing, 18).padding(.bottom, 6)
            }
            if let copied { Text("已复制\(copied)").font(.caption).foregroundColor(.secondary) }
        }.padding(20).frame(width: 440, height: 550)
            .onAppear(perform: model.load).onDisappear(perform: model.stop)
    }

    private func row(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack(alignment: .top) {
                Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "不可用")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let value, !value.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                        copied = label
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("复制" + label).accessibilityLabel("复制" + label)
                }
            }
        }
    }
}
