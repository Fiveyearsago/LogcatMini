import SwiftUI
import LogcatCore

struct IOSDeviceInfoView: View {
    @ObservedObject var ios: IOSLogViewModel
    @ObservedObject var idfa: IOSIDFAController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("设备信息").font(.title2.bold()); Spacer(); Button("关闭") { ios.infoShown = false } }
            Text(ios.device?.title ?? "设备已断开").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("IDFA · 独立 iOS 助手").font(.headline)
                        Spacer()
                        if idfa.busy {
                            ProgressView().controlSize(.small)
                            Button("取消", action: idfa.cancel)
                        } else {
                            Button(idfa.record == nil ? "读取 IDFA" : "重新读取 IDFA") { if let device = ios.device { idfa.read(device) } }.disabled(ios.device == nil)
                        }
                        Button("复制 IDFA", action: idfa.copy).disabled(idfa.busy || idfa.record?.result.usableIDFA == nil)
                    }
                    if ios.device?.kind == .usb {
                        HStack {
                            Text("签名团队")
                            TextField("Apple Team ID", text: $idfa.teamID).textFieldStyle(.roundedBorder).frame(width: 160).disabled(idfa.busy)
                            if !idfa.teams.isEmpty {
                                Menu("选择团队") {
                                    ForEach(idfa.teams) { team in Button("\(team.name) · \(team.id)") { idfa.teamID = team.id } }
                                }.disabled(idfa.busy)
                            }
                        }
                        Text("首次读取会用 Xcode 构建、签名并安装助手。手机须开启开发者模式；请在助手内选择是否允许跟踪。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let record = idfa.record {
                        Text(record.result.usableIDFA ?? "暂无可用 IDFA").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text(record.result.status)
                        Text("上次读取：\(record.readAt.formatted(date: .numeric, time: .standard)) · \(record.result.bundleID)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else { Text("尚未读取。设备的 UDID、序列号和 IMEI 都不是 IDFA。").font(.caption).foregroundStyle(.secondary) }
                    if !idfa.status.isEmpty { Text(idfa.status).font(.caption) }
                    if let error = idfa.error {
                        ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                        if idfa.record != nil { Text("本次读取未成功，上方保留的是上次结果。").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("授权状态仅属于本助手，不代表 Charge 等其他应用。结果只保存在本机；修改授权后请重新读取。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            if ios.infoLoading { ProgressView().controlSize(.small) }
            ScrollView { Text(ios.infoText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("复制设备信息") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ios.infoText, forType: .string) }.disabled(ios.infoLoading)
                Button("刷新设备信息", action: ios.showDeviceInfo).disabled(ios.infoLoading)
            }
        }.padding(20).frame(width: 740, height: 700)
            .task { idfa.select(ios.device); await idfa.loadTeams() }
            .onDisappear { idfa.cancel() }
    }
}
