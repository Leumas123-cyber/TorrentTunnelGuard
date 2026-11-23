import Foundation
import SwiftUI
import UserNotifications
import AppKit
import ServiceManagement
import Network

enum GuardStatus {
    case ok
    case wrongBinding
    case noTunnel

    var symbolName: String {
        switch self {
        case .ok: return "checkmark.shield.fill"
        case .wrongBinding: return "exclamationmark.shield.fill"
        case .noTunnel: return "shield.slash"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .wrongBinding: return .red
        case .noTunnel: return .orange
        }
    }

    var headline: String { headline(for: .qbittorrent) }

    func headline(for client: TorrentClient) -> String {
        switch self {
        case .ok: return "All sealed — \(client.title) is on the tunnel"
        case .wrongBinding: return "Wrong binding — leak risk"
        case .noTunnel: return "No VPN tunnel"
        }
    }
}

struct Snapshot {
    var client: TorrentClient = .qbittorrent
    var tunnel: TunnelInfo?
    var qbRunning: Bool
    var qbInterface: String?
    var qbAddress: String?
    var configPath: String?
    var writeTarget: String
    var webUI: WebUIReachability
    var bindingSource: String?
    var ipv6Hint: String?
    var lastPaused: Bool
    var checkedAt: Date

    var status: GuardStatus {
        guard let tunnel = tunnel else { return .noTunnel }
        return bindingMatchesTunnel(
            interface: qbInterface,
            address: qbAddress,
            tunnel: tunnel
        ) ? .ok : .wrongBinding
    }

    /// Short hover text for the menu-bar icon — no need to open the window.
    var menuBarTooltip: String {
        MenuBarTooltip.text(tunnel: tunnel?.iface, qbInterface: qbInterface,
                            clientName: client.shortName)
    }
}

func bindingMatchesTunnel(interface: String?, address: String?,
                          tunnel: TunnelInfo) -> Bool {
    guard interface == tunnel.iface else { return false }
    guard let address, !address.isEmpty,
          let tunnelIP = tunnel.ip, !tunnelIP.isEmpty else {
        return true
    }
    return address == tunnelIP
}

func shouldPauseTorrents(previous: GuardStatus?, current: GuardStatus) -> Bool {
    previous != .noTunnel && current == .noTunnel
}

func shouldNotifyProblem(status: GuardStatus, lastNotified: GuardStatus?,
                         notificationsEnabled: Bool, requested: Bool) -> Bool {
    requested && notificationsEnabled && status != .ok && lastNotified != status
}

struct CheckRequestQueue {
    private(set) var hasPending = false
    private(set) var shouldNotify = false

    mutating func enqueue(notify: Bool) {
        hasPending = true
        shouldNotify = shouldNotify || notify
    }

    mutating func take() -> Bool? {
        guard hasPending else { return nil }
        let notify = shouldNotify
        hasPending = false
        shouldNotify = false
        return notify
    }
}

struct NotificationEpisodeGate {
    private(set) var active = false

    mutating func shouldPost() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    mutating func reset() {
        active = false
    }
}

@MainActor
final class GuardState: ObservableObject {
    static let shared = GuardState()

    @Published var snapshot: Snapshot?
    @Published var checking = false
    @Published var lastAction: String?
    @Published var lastError: String?
    private var lastNotifiedStatus: GuardStatus?
    private var autoFixBlockedNotification = NotificationEpisodeGate()

    @Published var autoWatch: Bool {
        didSet { defaults.set(autoWatch, forKey: "autoWatch"); rescheduleTimer(); startPathMonitor() }
    }
    @Published var autoFix: Bool {
        didSet { defaults.set(autoFix, forKey: "autoFix") }
    }
    @Published var notifications: Bool {
        didSet { defaults.set(notifications, forKey: "notifications"); if notifications { askNotificationPermission() } }
    }
    @Published var watchInterval: Double {
        didSet { defaults.set(watchInterval, forKey: "watchInterval"); rescheduleTimer() }
    }
    /// Which torrent app is guarded. The Web UI / RPC fields below hold the
    /// settings of this client; each client keeps its own.
    @Published var torrentClient: TorrentClient {
        didSet {
            guard torrentClient != oldValue else { return }
            defaults.set(torrentClient.rawValue, forKey: "torrentClient")
            loadRemoteSettings()
            loginTestResult = nil
            lastAction = nil
            lastError = nil
            Task { await checkNow(notifyAbout: false) }
        }
    }
    @Published var webuiEnabled: Bool {
        didSet { defaults.set(webuiEnabled, forKey: torrentClient.defaultsKey("webuiEnabled")) }
    }
    @Published var webuiURL: String {
        didSet { defaults.set(webuiURL, forKey: torrentClient.defaultsKey("webuiURL")) }
    }
    @Published var webuiUser: String {
        didSet { defaults.set(webuiUser, forKey: torrentClient.defaultsKey("webuiUser")) }
    }
    @Published var webuiPass: String {
        didSet {
            guard !isHydrating else { return }
            let account = torrentClient.keychainAccount
            if webuiPass.isEmpty {
                KeychainStore.deletePassword(service: KeychainStore.service, account: account)
            } else {
                if !KeychainStore.savePassword(webuiPass, service: KeychainStore.service,
                                               account: account) {
                    lastError = "Could not save the \(torrentClient.remoteTitle) password in Keychain."
                }
            }
        }
    }

    /// Credentials are complete enough to try the selected client's remote API.
    var remoteCredentialsReady: Bool {
        torrentClient.credentialsReady(user: webuiUser, password: webuiPass)
    }
    @Published var vpnProvider: VPNProvider {
        didSet { defaults.set(vpnProvider.rawValue, forKey: "vpnProvider") }
    }
    @Published var pauseOnDrop: Bool {
        didSet { defaults.set(pauseOnDrop, forKey: "pauseOnDrop") }
    }
    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: "onboardingDone") }
    }
    @Published var checkUpdates: Bool {
        didSet { defaults.set(checkUpdates, forKey: "checkUpdates") }
    }
    @Published var updateAvailable: UpdateInfo?
    @Published var updateCheckMessage: String?
    @Published var loginTestResult: String?

    var menuBarTooltip: String {
        snapshot?.menuBarTooltip ?? MenuBarTooltip.unchecked
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var clientQuitObserver: Any?
    private var powerObserver: Any?
    private var pathMonitor: NWPathMonitor?
    private var pathDebounce: DispatchWorkItem?
    private var isHydrating = true
    private var didCheckUpdate = false
    private var checkQueue = CheckRequestQueue()

    private init() {
        autoWatch = defaults.object(forKey: "autoWatch") as? Bool ?? true
        autoFix = defaults.object(forKey: "autoFix") as? Bool ?? false
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        watchInterval = defaults.object(forKey: "watchInterval") as? Double ?? 5
        let client = TorrentClient(rawValue: defaults.string(forKey: "torrentClient") ?? "")
            ?? .qbittorrent
        torrentClient = client
        webuiEnabled = defaults.bool(forKey: client.defaultsKey("webuiEnabled"))
        webuiURL = defaults.string(forKey: client.defaultsKey("webuiURL")) ?? client.defaultRemoteURL
        webuiUser = defaults.string(forKey: client.defaultsKey("webuiUser")) ?? ""
        let legacyPass = KeychainStore.migrateFromUserDefaults(defaults)
        webuiPass = client == .qbittorrent
            ? legacyPass
            : KeychainStore.loadPassword(service: KeychainStore.service,
                                         account: client.keychainAccount) ?? ""
        vpnProvider = VPNProvider(rawValue: defaults.string(forKey: "vpnProvider") ?? "") ?? .auto
        pauseOnDrop = defaults.object(forKey: "pauseOnDrop") as? Bool ?? true
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        checkUpdates = defaults.object(forKey: "checkUpdates") as? Bool ?? true
        isHydrating = false

        clientQuitObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            let bundleID = app.bundleIdentifier
            let name = app.localizedName
            let state = self
            Task { @MainActor in
                guard state?.torrentClient.matchesApp(bundleID: bundleID, name: name) == true
                else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await state?.checkNow(notifyAbout: false)
                if state?.autoFix == true {
                    _ = await state?.attemptFix(automatic: true)
                }
            }
        }

        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = self
            Task { @MainActor in state?.rescheduleTimer() }
        }

        Task { await checkNow() }
        rescheduleTimer()
        startPathMonitor()
        scheduleUpdateCheck()
    }

    func start() {
        Task { await checkNow() }
        rescheduleTimer()
        startPathMonitor()
        if notifications { askNotificationPermission() }
        scheduleUpdateCheck()
    }

    /// Pulls the selected client's Web UI / RPC settings into the shared fields.
    private func loadRemoteSettings() {
        let client = torrentClient
        isHydrating = true
        webuiEnabled = defaults.bool(forKey: client.defaultsKey("webuiEnabled"))
        webuiURL = defaults.string(forKey: client.defaultsKey("webuiURL")) ?? client.defaultRemoteURL
        webuiUser = defaults.string(forKey: client.defaultsKey("webuiUser")) ?? ""
        webuiPass = KeychainStore.loadPassword(service: KeychainStore.service,
                                               account: client.keychainAccount) ?? ""
        isHydrating = false
    }

    func scheduleUpdateCheck() {
        guard checkUpdates, !didCheckUpdate else { return }
        didCheckUpdate = true
        Task { await checkForUpdate() }
    }

    func checkForUpdate() async {
        updateCheckMessage = nil
        let current = UpdateCheck.currentVersion()
        guard let latest = await UpdateCheck.fetchLatest() else {
            updateCheckMessage = "Could not reach GitHub Releases"
            return
        }
        let tag = UpdateCheck.normalize(latest.tag)
        if UpdateCheck.isNewer(latest.tag, than: current) {
            updateAvailable = UpdateInfo(latest: tag, current: current, htmlURL: latest.htmlURL)
            updateCheckMessage = "Version \(tag) is available (you have \(current))"
        } else {
            updateAvailable = nil
            updateCheckMessage = "You’re on \(current) — latest is \(tag)"
        }
    }

    func openLatestRelease() {
        let candidate = updateAvailable?.htmlURL
        let destination = candidate.map(UpdateCheck.isTrustedReleaseURL) == true
            ? candidate!
            : UpdateCheck.releasesPage
        NSWorkspace.shared.open(destination)
    }

    func checkNow(notifyAbout: Bool = true) async {
        if checking {
            checkQueue.enqueue(notify: notifyAbout)
            return
        }
        checking = true
        defer { checking = false }

        var shouldNotify = notifyAbout
        while true {
            await performCheck(notifyAbout: shouldNotify)
            guard let queuedNotification = checkQueue.take() else { break }
            shouldNotify = queuedNotification
        }
    }

    private func performCheck(notifyAbout: Bool) async {
        let snap = await gather()
        let previous = snapshot?.status
        snapshot = snap

        if shouldPauseTorrents(previous: previous, current: snap.status) {
            await pauseTorrentsIfNeeded()
        }
        var fixApplied = false
        if autoFix, snap.status == .wrongBinding {
            fixApplied = await attemptFix(automatic: true)
        }

        if snap.status != .wrongBinding {
            autoFixBlockedNotification.reset()
        }
        if snap.status == .ok {
            lastNotifiedStatus = nil
        } else if !fixApplied, shouldNotifyProblem(
            status: snap.status,
            lastNotified: lastNotifiedStatus,
            notificationsEnabled: notifications,
            requested: notifyAbout
        ) {
            notifyProblem(snap)
            lastNotifiedStatus = snap.status
        }
    }

    private func gather() async -> Snapshot {
        let probeURL = webuiEnabled ? WebUIURLValidator.validated(webuiURL) : nil
        let enabled = webuiEnabled
        let user = webuiUser
        let pass = webuiPass
        let provider = vpnProvider
        let client = torrentClient
        let credentialsReady = remoteCredentialsReady
        return await Task.detached(priority: .utility) {
            let ifconfigText = Shell.run("/sbin/ifconfig", ["-a"])
            let ifaces = IfconfigParser.parse(ifconfigText)
            let tunnel = Detector.detect(
                provider: provider,
                ifconfigText: ifconfigText,
                routeText: Shell.run("/sbin/route", ["-n", "get", "default"]),
                netstatText: Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]),
                processText: Shell.run("/usr/bin/pgrep", ["-ifl", provider.pgrepPattern])
            )
            let clientProcesses = Detector.clientProcessText(client)
            let config = ClientConfigState.read(client: client, ifaces: ifaces,
                                                processText: clientProcesses)
            var iface = config.iface
            var addr = config.addr
            var source = config.source
            var webUI: WebUIReachability = .unused
            if enabled, let probeURL {
                webUI = await TorrentRemote.probe(client: client, baseURL: probeURL)
                if webUI == .online, credentialsReady {
                    let remote = TorrentRemote(client: client, baseURL: probeURL,
                                               user: user, password: pass)
                    if await remote.login(),
                       let live = await remote.currentBinding(ifaces: ifaces) {
                        iface = live.iface
                        addr = live.addr ?? addr
                        source = client.remoteTitle
                    }
                }
            }
            return Snapshot(
                client: client,
                tunnel: tunnel,
                qbRunning: Detector.clientRunning(client, processText: clientProcesses),
                qbInterface: iface,
                qbAddress: addr,
                configPath: config.configPath,
                writeTarget: config.writeTarget,
                webUI: webUI,
                bindingSource: source,
                ipv6Hint: Detector.ipv6Hint(ifconfigText: ifconfigText, tunnel: tunnel?.iface),
                lastPaused: false,
                checkedAt: Date()
            )
        }.value
    }

    @discardableResult
    func attemptFix(automatic: Bool) async -> Bool {
        guard let snap = snapshot else { return false }
        guard let tunnel = snap.tunnel else {
            lastError = "No tunnel — connect the VPN first."
            return false
        }
        let client = torrentClient
        if client != .qbittorrent, tunnel.ip == nil {
            lastError = "The tunnel \(tunnel.iface) has no IPv4 address yet — \(client.title) binds by IP."
            return false
        }

        if webuiEnabled, remoteCredentialsReady, client.supportsLiveRebind {
            guard let url = WebUIURLValidator.validated(webuiURL) else {
                lastError = "\(client.remoteTitle) must use localhost, 127.0.0.1, or ::1."
                return false
            }
            let remote = TorrentRemote(client: client, baseURL: url,
                                       user: webuiUser, password: webuiPass)
            if await remote.login() {
                let keep = snap.qbAddress == tunnel.ip ? snap.qbAddress : nil
                if await remote.setBinding(interface: tunnel.iface, address: tunnel.ip,
                                           keepAddress: keep) {
                    lastAction = "\(client.remoteTitle): binding set live to \(tunnel.iface) ✓"
                    lastError = nil
                    await checkNow()
                    return true
                }
            }
            lastError = "\(client.remoteTitle) login failed (check URL / user / password)."
        }

        if snap.qbRunning {
            if client.supportsLiveRebind {
                lastError = "\(client.title) is still running — quit it (button below) or enable the \(client.remoteTitle)."
            } else {
                lastError = "\(client.title) is still running — quit it (button below); its bind address only changes on restart."
            }
            if automatic, notifications, autoFixBlockedNotification.shouldPost() {
                postNotification("Surfshark Guard — action needed",
                                 "\(client.title) is on the wrong binding. Quit the app so the fix can apply.")
                lastNotifiedStatus = .wrongBinding
            }
            return false
        }

        do {
            let lines: [String]
            switch client {
            case .qbittorrent:
                lines = try QBittorrent.writeBinding(
                    interface: tunnel.iface, tunnelIP: tunnel.ip,
                    oldAddress: snap.qbAddress)
            case .transmission:
                lines = try TransmissionConfig.writeBindAddress(tunnel.ip ?? "")
            case .deluge:
                lines = try DelugeConfig.writeBinding(interface: tunnel.iface,
                                                      address: tunnel.ip ?? "")
            }
            lastAction = "Binding written: " + lines.joined(separator: ", ")
            lastError = nil
            if automatic {
                postNotification("Surfshark Guard — binding fixed",
                                 "\(client.title) is quit — binding is now \(tunnel.iface). Start it again.")
            }
            autoFixBlockedNotification.reset()
            await checkNow()
            return true
        } catch {
            lastError = "Could not write the config: \(error.localizedDescription)"
            return false
        }
    }

    func quitQBittorrentAndFix() async {
        await quitClientAndFix()
    }

    func quitClientAndFix() async {
        let client = torrentClient
        let apps = NSWorkspace.shared.runningApplications.filter {
            client.matchesApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        guard !apps.isEmpty else {
            if Detector.clientRunning(client) {
                lastError = "\(client.title) runs as a background service — stop it, then press Check now."
            } else {
                _ = await attemptFix(automatic: false)
            }
            return
        }
        lastAction = "Quitting \(client.title)…"
        apps.forEach { _ = $0.terminate() }
        for _ in 0..<20 {
            if !Detector.clientRunning(client) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !Detector.clientRunning(client) {
            await checkNow(notifyAbout: false)
            _ = await attemptFix(automatic: false)
        }
    }

    var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            lastError = "Could not set login item: \(error.localizedDescription) " +
                        "(copy the app to /Applications, don’t launch from .build)"
        }
    }

    /// Never tighter than 5 s. Low Power Mode stretches the gap so route/ifconfig
    /// is not a tight loop.
    private var effectiveWatchInterval: TimeInterval {
        let floor: TimeInterval = 5
        let base = max(watchInterval, floor)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return max(base, 15) }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return max(base, 30)
        default: return base
        }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoWatch else { return }
        let interval = effectiveWatchInterval
        let scheduled = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            let state = self
            Task { @MainActor in
                await state?.checkNow()
            }
        }
        scheduled.tolerance = min(2, interval * 0.3)
        timer = scheduled
    }

    private func startPathMonitor() {
        pathMonitor?.cancel()
        guard autoWatch else {
            pathMonitor = nil
            return
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let state = self else { return }
                state.pathDebounce?.cancel()
                let work = DispatchWorkItem {
                    Task { @MainActor in
                        await state.checkNow()
                    }
                }
                state.pathDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    func testWebUILogin() async {
        loginTestResult = nil
        guard let url = WebUIURLValidator.validated(webuiURL) else {
            loginTestResult = "Use a local \(torrentClient.remoteTitle) URL (localhost, 127.0.0.1, or ::1)"
            return
        }
        let remote = TorrentRemote(client: torrentClient, baseURL: url,
                                   user: webuiUser, password: webuiPass)
        if await remote.login() {
            loginTestResult = "Login works"
        } else {
            loginTestResult = "Login failed — check user / password / \(torrentClient.remoteTitle)"
        }
    }

    private func pauseTorrentsIfNeeded() async {
        guard pauseOnDrop, webuiEnabled, remoteCredentialsReady,
              let url = WebUIURLValidator.validated(webuiURL) else { return }
        let client = torrentClient
        let remote = TorrentRemote(client: client, baseURL: url,
                                   user: webuiUser, password: webuiPass)
        guard await remote.login() else { return }
        if await remote.pauseAllTorrents() {
            lastAction = "VPN dropped — paused all torrents"
            if var snap = snapshot { snap.lastPaused = true; snapshot = snap }
            postNotification("Surfshark Guard — torrents paused",
                             "The VPN tunnel went down, so \(client.title) was paused.")
        }
    }

    private func askNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
        }
    }

    private func notifyProblem(_ snap: Snapshot) {
        let text: String
        switch snap.status {
        case .wrongBinding:
            text = "\(snap.client.title) is on \(snap.qbInterface ?? "no interface"), the tunnel is \(snap.tunnel?.iface ?? "?")"
        case .noTunnel:
            text = "No VPN tunnel — torrents should stay paused."
        case .ok:
            return
        }
        postNotification("Surfshark Guard", text)
    }

    private func postNotification(_ title: String, _ body: String) {
        guard notifications, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
