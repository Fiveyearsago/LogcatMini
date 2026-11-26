import AppKit
import Combine
import LogcatCore

@MainActor final class IOSIDFAController: ObservableObject {
    struct Record: Codable { let deviceID: String; let result: IOSIDFAResult; let readAt: Date }
    typealias Reader = (IOSDevice, String, @escaping @MainActor @Sendable (String) -> Void) async throws -> IOSIDFAResult
    @Published var teamID: String { didSet { defaults.set(teamID, forKey: "ios.idfa.team") } }
    @Published private(set) var teams: [IOSSigningTeam] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var record: Record?
    private var deviceID: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let defaults: UserDefaults
    private let reader: Reader
    init(defaults: UserDefaults = .standard, reader: Reader? = nil) {
        self.defaults = defaults
        teamID = defaults.string(forKey: "ios.idfa.team") ?? ""
        self.reader = reader ?? { device, team, progress in try await IOSIDFAService().read(device: device, team: team, progress: progress) }
    }
    func loadTeams() async {
        teams = await Task.detached { IOSSigningTeam.available() }.value
        if teamID.isEmpty, teams.count == 1 { teamID = teams[0].id }
    }
    func select(_ device: IOSDevice?) {
        guard deviceID != device?.id else { return }
        cancel()
        deviceID = device?.id; error = nil; status = ""
        record = deviceID.flatMap { defaults.data(forKey: "ios.idfa.record." + $0) }.flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        if record?.deviceID != deviceID { record = nil }
    }
    func read(_ device: IOSDevice) {
        select(device)
        guard !busy else { return }
        let request = UUID(); generation = request
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        teamID = team
        busy = true; error = nil; status = "准备读取…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await reader(device, team) { [weak self] text in
                    guard let self, self.generation == request else { return }
                    self.status = text
                }
                guard !Task.isCancelled, generation == request, deviceID == device.id else { return }
                let value = Record(deviceID: device.id, result: result, readAt: Date())
                record = value
                defaults.set(try? JSONEncoder().encode(value), forKey: "ios.idfa.record." + device.id)
                status = "读取完成"
            } catch {
                guard generation == request else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription; status = "读取失败" }
            }
            guard generation == request else { return }
            busy = false; task = nil
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if busy { status = "已取消" }; busy = false
    }
    func copy() {
        guard let value = record?.result.usableIDFA else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}
