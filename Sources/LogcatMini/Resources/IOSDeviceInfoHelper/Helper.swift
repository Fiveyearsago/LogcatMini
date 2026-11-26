import UIKit
import AdSupport
import AppTrackingTransparency

@main
final class HelperApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Main", sessionRole: session.role)
        configuration.delegateClass = HelperScene.self
        return configuration
    }
}

final class HelperScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = HelperViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? HelperViewController)?.refresh()
    }
}

final class HelperViewController: UIViewController {
    private let value = UILabel()
    private let status = UILabel()
    private let notice = UILabel()
    private let copyButton = UIButton(type: .system)
    private let authorizeButton = UIButton(type: .system)
    private var identifier: String?
    private var requestID: String {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--request-id"), args.indices.contains(index + 1),
              UUID(uuidString: args[index + 1]) != nil else { return "standalone" }
        return args[index + 1]
    }
    private var simulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Logcat Mini · IDFA 助手"
        title.font = .preferredFont(forTextStyle: .title1)
        title.numberOfLines = 0
        let explanation = UILabel()
        explanation.text = "在本机查看广告标识符，也可通过 USB 返回给 Mac 上的 Logcat Mini。助手不上传数据。\n\n这里的跟踪授权仅属于本助手，不代表 Charge 或其他应用的授权状态。"
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.numberOfLines = 0
        value.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        value.numberOfLines = 0
        value.accessibilityIdentifier = "idfaValue"
        status.numberOfLines = 0
        status.accessibilityIdentifier = "idfaStatus"
        notice.numberOfLines = 0
        notice.textColor = .secondaryLabel
        authorizeButton.setTitle("授权并读取 IDFA", for: .normal)
        authorizeButton.addTarget(self, action: #selector(authorize), for: .touchUpInside)
        copyButton.setTitle("复制 IDFA", for: .normal)
        copyButton.accessibilityIdentifier = "copyIDFA"
        copyButton.addTarget(self, action: #selector(copyIDFA), for: .touchUpInside)
        var copyConfiguration = UIButton.Configuration.filled()
        copyConfiguration.cornerStyle = .medium
        copyButton.configuration = copyConfiguration
        let refreshButton = UIButton(type: .system)
        refreshButton.setTitle("刷新", for: .normal)
        refreshButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        let settingsButton = UIButton(type: .system)
        settingsButton.setTitle("打开助手设置", for: .normal)
        settingsButton.addTarget(self, action: #selector(settings), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, explanation, status, value, authorizeButton, copyButton, refreshButton, settingsButton, notice])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        refresh()
    }
    @objc func refresh() {
        guard isViewLoaded else { return }
        let authorization = ATTrackingManager.trackingAuthorizationStatus
        let raw = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        identifier = !simulator && authorization == .authorized && raw != "00000000-0000-0000-0000-000000000000" ? raw : nil
        let state: String
        let label: String
        switch authorization {
        case .notDetermined: state = "notDetermined"; label = "尚未请求授权"
        case .restricted: state = "restricted"; label = "跟踪授权受限制"
        case .denied: state = "denied"; label = "未允许跟踪"
        case .authorized: state = "authorized"; label = "已允许跟踪"
        @unknown default: state = "unknown"; label = "未知授权状态"
        }
        status.text = simulator ? "模拟器没有可用的 IDFA" : "助手授权状态：" + label
        value.text = identifier ?? "暂无可用 IDFA"
        copyButton.isEnabled = identifier != nil
        authorizeButton.isHidden = simulator || authorization != .notDetermined
        notice.text = identifier == nil ? "只有真机上允许本助手跟踪，系统才可能返回有效 IDFA。可在设置中更改授权后刷新。" : "读取成功，可复制到剪贴板。"
        let result: [String: Any] = ["schemaVersion": 1, "requestID": requestID,
            "bundleID": Bundle.main.bundleIdentifier ?? "", "idfa": identifier ?? "00000000-0000-0000-0000-000000000000",
            "authorization": state, "isSimulator": simulator, "generatedAt": Date().timeIntervalSince1970]
        do {
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("idfa-result.json")
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { notice.text = "读取完成，但向 Mac 返回结果失败：\(error.localizedDescription)" }
    }
    @objc private func authorize() {
        ATTrackingManager.requestTrackingAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    @objc private func copyIDFA() {
        // Re-read permission first: never copy an identifier cached before a settings change.
        refresh()
        guard let identifier else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: identifier]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        notice.text = "IDFA 已复制（5 分钟后过期）"
        UIAccessibility.post(notification: .announcement, argument: "IDFA 已复制")
    }
    @objc private func settings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
