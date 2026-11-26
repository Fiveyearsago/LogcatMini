import Foundation
import Combine

@MainActor final class BastionManager: ObservableObject {
    enum Status: Equatable {
        case power(BastionPower), pending, failed(String)
        var label: String {
            switch self {
            case .power(let power): return power.label
            case .pending: return "开机结果待确认"
            case .failed(let reason): return reason
            }
        }
    }
    enum Action { case refresh, start, connect }
    @Published private(set) var apps: [BastionApp] = []
    @Published private(set) var userName: String?
    @Published private(set) var platformURL = ""
    @Published private(set) var accountUnreadable = false
    @Published private(set) var catalogUnreadable = false
    @Published private(set) var savingAccount = false
    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var busy: [String: Action] = [:]
    @Published var error: String?

    private let storage: BastionStorage
    private let makePortal: (BastionAccount) -> BastionPortal
    private let openDesktop: (String) async throws -> Void
    private var portal: BastionPortal?
    private struct PendingStart {
        let sent = Date()
        var acknowledged = false
    }
    private var pending: [String: PendingStart] = [:]
    var openingDesktop: Bool { busy.values.contains(.connect) }
    var actionInProgress: Bool { busy.values.contains { $0 != .refresh } }

    init(storage: BastionStorage = BastionStorage(), makePortal: ((BastionAccount) -> BastionPortal)? = nil,
         openDesktop: @escaping (String) async throws -> Void = BastionDesktop.open) {
        self.storage = storage
        self.makePortal = makePortal ?? { BastionPortal($0) }
        self.openDesktop = openDesktop
        do { apps = try storage.loadApps() }
        catch { catalogUnreadable = true; self.error = "无法读取应用列表，原文件已保留。" }
        do {
            if let account = try storage.loadAccount() {
                portal = self.makePortal(account)
                userName = account.userName
                platformURL = account.platformURL ?? ""
            }
        } catch { accountUnreadable = true }
    }

    func saveApp(_ draft: BastionApp) throws {
        let app = try draft.validated()
        var next = apps
        if let index = next.firstIndex(where: { $0.id == app.id }) {
            try allowEdit(next[index])
            next[index] = app
        } else { next.append(app) }
        try persist(next)
    }
    func removeApp(_ app: BastionApp) throws {
        try allowEdit(app)
        try persist(apps.filter { $0.id != app.id })
    }
    private func allowEdit(_ app: BastionApp) throws {
        if let action = busy[app.ip], action != .refresh { throw BastionError("请等待该跳板机的操作完成。") }
    }
    private func persist(_ next: [BastionApp]) throws {
        guard !catalogUnreadable else { throw BastionError("无法读取已有应用配置，请检查 apps.json。") }
        try storage.saveApps(next)
        apps = next
        let ips = Set(next.map(\.ip))
        statuses = statuses.filter { ips.contains($0.key) }
    }

    func saveAccount(userName: String, password: String, platformURL: String) async throws {
        guard !actionInProgress, !savingAccount else { throw BastionError("请等待当前操作完成。") }
        let account = try BastionAccount(userName: userName, password: password, platformURL: platformURL)
        savingAccount = true
        defer { savingAccount = false }
        let candidate = makePortal(account)
        try await candidate.verify()
        try storage.saveAccount(account)
        self.platformURL = account.platformURL ?? ""
        setAccount(account.userName, portal: candidate)
    }
    func removeAccount() throws {
        guard !actionInProgress, !savingAccount else { throw BastionError("请等待当前操作完成。") }
        try storage.removeAccount()
        platformURL = ""
        setAccount(nil, portal: nil)
    }
    private func setAccount(_ name: String?, portal: BastionPortal?) {
        self.portal = portal; userName = name; accountUnreadable = false
        statuses.removeAll(); busy.removeAll()
    }

    func refreshAll() async {
        let session = portal
        guard session != nil else { return }
        var seen = Set<String>()
        let targets = apps.filter { seen.insert($0.ip).inserted }
        // Limit concurrent reads and share a single login for all rows.
        await withTaskGroup(of: Void.self) { group in
            for (index, app) in targets.enumerated() {
                if index >= 4 { await group.next() }
                guard !Task.isCancelled, session === portal else { break }
                group.addTask { await self.perform(.refresh, for: app) }
            }
        }
    }

    func perform(_ action: Action, for app: BastionApp) async {
        let ip = app.ip
        guard let session = portal, !savingAccount, busy[ip] == nil, apps.contains(where: { $0.id == app.id && $0.ip == ip }) else { return }
        if action == .start && statuses[ip] != .power(.stopped) { return }
        if action == .connect && (openingDesktop || statuses[ip] != .power(.running)) { return }
        busy[ip] = action
        defer { if session === portal { busy[ip] = nil } }
        func hasTarget() -> Bool { session === portal && apps.contains { $0.ip == ip } }
        do {
            let host = try await session.host(ip)
            guard hasTarget(), !Task.isCancelled else { return }
            update(host.power, ip: ip)
            switch action {
            case .refresh: break
            case .connect:
                guard host.power == .running else { return }
                do { try await openDesktop(ip) }
                catch { self.error = error.localizedDescription }
            case .start:
                guard statuses[ip] == .power(.stopped) else { return }
                pending[ip] = PendingStart()
                statuses[ip] = .pending
                do {
                    try await session.start(host)
                    pending[ip]?.acknowledged = true
                }
                catch let failure as BastionPortalError where failure.definitelyRejected {
                    pending[ip] = nil
                    throw failure
                }
                let current = try await session.host(ip)
                if hasTarget() { update(current.power, ip: ip) }
            }
        } catch {
            guard hasTarget(), !Task.isCancelled else { return }
            if pending[ip] != nil {
                statuses[ip] = .pending
                if action != .refresh { self.error = "开机结果待确认，请刷新状态。\n" + error.localizedDescription }
            } else {
                statuses[ip] = .failed(error.localizedDescription)
            }
        }
    }

    private func update(_ power: BastionPower, ip: String) {
        if let request = pending[ip] {
            let age = Date().timeIntervalSince(request.sent)
            switch power {
            case .stopped, .unknown:
                if age < 660 {
                    statuses[ip] = request.acknowledged && age < 120 ? .power(.starting) : .pending
                    return
                }
                pending[ip] = nil
            case .starting: break
            default: pending[ip] = nil
            }
        }
        statuses[ip] = .power(power)
    }

    var transitioning: [String] {
        statuses.compactMap { ip, value in
            switch value {
            case .pending, .power(.starting), .power(.stopping): return ip
            default: return nil
            }
        }.sorted()
    }
}
