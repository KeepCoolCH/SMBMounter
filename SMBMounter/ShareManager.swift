import Foundation
import Combine
import AppKit
import Network
import UserNotifications

class ShareManager: ObservableObject {
    static let shared = ShareManager()

    @Published var shares: [SMBShare] = []

    private let stateQueue = DispatchQueue(label: "com.smbmounter.state")
    private var manuallyDisconnected: Set<UUID> = []
    private var pendingMounts: Set<UUID> = []
    private var extraRetryCount: [UUID: Int] = [:]
    private var failCount: [UUID: Int] = [:]
    private let maxExtraRetriesAfterDisconnect = 3

    private let mountQueue = DispatchQueue(label: "com.smbmounter.mount.serial", qos: .utility)
    private let unmountQueue = DispatchQueue(label: "com.smbmounter.unmount", qos: .utility)
    private let monitorQueue = DispatchQueue(label: "com.smbmounter.monitor", qos: .background)

    private var recoveryTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var isNetworkAvailable = false

    private let unmountStatusRefreshDelay: TimeInterval = 1.0
    private let unmountReconnectDelay: TimeInterval = 1.0
    private let initialReconnectAttemptDelay: TimeInterval = 1.0
    private let reconnectTickInterval: TimeInterval = 1.5
    private let shortRetryInterval: TimeInterval = 0.35

    private let requiredStableSuccesses = 2
    private let bonjourCheckCycles = 4
    private let smbReachabilityTimeout: TimeInterval = 2.0
    private let bonjourQueryTimeout: TimeInterval = 2.0

    private let finderAppleScriptTimeoutSeconds = 2.0
    private let finderExecutionTimeout: TimeInterval = 10.0
    private let postMountVerifyTimeout: TimeInterval = 5.0

    private let postBootAutoConnectDelay: TimeInterval = 15.0
    private let normalLaunchAutoConnectDelay: TimeInterval = 1.0
    private var startupReadyAt: Date?
    private var startupReconnectScheduled = false

    private var hostProbeWindow: TimeInterval {
        let reachabilityBudget = Double(requiredStableSuccesses) * ((smbReachabilityTimeout * 2.0) + shortRetryInterval)
        let bonjourBudget = Double(bonjourCheckCycles) * (bonjourQueryTimeout + shortRetryInterval)
        return max(8.0, reachabilityBudget + bonjourBudget)
    }

    private var mountCycleTimeout: TimeInterval {
        hostProbeWindow + 10.0
    }

    private init() {
        loadShares()
    }

    // MARK: - State

    private func markManuallyDisconnected(_ id: UUID) {
        stateQueue.sync {
            _ = manuallyDisconnected.insert(id)
        }
    }

    private func clearManuallyDisconnected(_ id: UUID) {
        stateQueue.sync {
            _ = manuallyDisconnected.remove(id)
        }
    }

    private func isManuallyDisconnected(_ id: UUID) -> Bool {
        stateQueue.sync { manuallyDisconnected.contains(id) }
    }

    private func beginPendingMount(_ id: UUID) -> Bool {
        stateQueue.sync {
            if pendingMounts.contains(id) {
                return false
            }
            _ = pendingMounts.insert(id)
            return true
        }
    }

    private func endPendingMount(_ id: UUID) {
        stateQueue.sync {
            _ = pendingMounts.remove(id)
        }
    }

    private func isPendingMount(_ id: UUID) -> Bool {
        stateQueue.sync { pendingMounts.contains(id) }
    }

    private func consumeExtraRetry(_ id: UUID) -> Bool {
        stateQueue.sync {
            let current = extraRetryCount[id] ?? 0
            if current >= maxExtraRetriesAfterDisconnect {
                return false
            }
            extraRetryCount[id] = current + 1
            return true
        }
    }

    private func clearExtraRetry(_ id: UUID) {
        stateQueue.sync {
            extraRetryCount[id] = nil
        }
    }

    private func scheduleOneExtraRetryIfNeeded(for shareID: UUID, delay: TimeInterval = 0.8) {
        guard consumeExtraRetry(shareID) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.isNetworkAvailable else { return }
            guard !self.isManuallyDisconnected(shareID) else { return }
            guard let share = self.shares.first(where: { $0.id == shareID }) else { return }
            guard share.status == .disconnected else { return }
            guard !self.isMounted(share) else { return }

            self.mount(share)
        }
    }

    // MARK: - Persistence

    private var savePath: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("SMBMounter")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("shares.json")
    }

    func saveShares() {
        if let data = try? JSONEncoder().encode(shares) {
            try? data.write(to: savePath)
        }
    }

    func loadShares() {
        guard let data = try? Data(contentsOf: savePath),
              let decoded = try? JSONDecoder().decode([SMBShare].self, from: data) else { return }
        shares = decoded
    }

    // MARK: - Monitoring

    func startMonitoring() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let remainingBootDelay = max(0, postBootAutoConnectDelay - uptime)
        let startupDelay = max(normalLaunchAutoConnectDelay, remainingBootDelay)

        startupReadyAt = Date().addingTimeInterval(startupDelay)
        startupReconnectScheduled = false

        let nm = NWPathMonitor()
        nm.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = available

                if available && !wasAvailable {
                    self.startReconnectTimer()
                } else if !available {
                    self.stopReconnectTimer()
                    self.setAllDisconnectedSilently()
                }
            }
        }
        nm.start(queue: monitorQueue)
        networkMonitor = nm

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay) {
            guard self.isNetworkAvailable else { return }
            self.startReconnectTimer()
        }
    }

    func stopMonitoring() {
        stopReconnectTimer()
        networkMonitor?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func volumeDidUnmount(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + unmountStatusRefreshDelay) {
            self.updateMountStatuses()
            let hasDisconnected = self.shares.contains {
                $0.autoMount && !self.isManuallyDisconnected($0.id) && !self.isMounted($0)
            }
            if hasDisconnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.unmountReconnectDelay) {
                    self.startReconnectTimer()
                }
            }
        }
    }

    // MARK: - Reconnect Timer

    private func startReconnectTimer() {
        guard recoveryTimer == nil else { return }
        guard isNetworkAvailable else { return }

        if let readyAt = startupReadyAt, Date() < readyAt {
            guard !startupReconnectScheduled else { return }
            startupReconnectScheduled = true
            let delay = max(0, readyAt.timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.startupReconnectScheduled = false
                self.startReconnectTimer()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + initialReconnectAttemptDelay) {
            guard self.isNetworkAvailable else { return }
            self.mountAllAutoShares()
        }

        recoveryTimer = Timer.scheduledTimer(withTimeInterval: reconnectTickInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isNetworkAvailable else { return }
            self.mountAllAutoShares()

            let allMounted = self.shares
                .filter { $0.autoMount && !self.isManuallyDisconnected($0.id) }
                .allSatisfy { self.isMounted($0) }

            if allMounted {
                self.stopReconnectTimer()
            }
        }
    }

    private func stopReconnectTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func setAllDisconnectedSilently() {
        for i in shares.indices {
            if shares[i].status != .disconnected {
                shares[i].status = .disconnected
                shares[i].lastError = nil
            }
        }
        stateQueue.sync {
            manuallyDisconnected.removeAll()
            pendingMounts.removeAll()
            extraRetryCount.removeAll()
        }
        failCount = [:]
        updateAppIcon()
    }

    func mountAllAutoShares() {
        guard isNetworkAvailable else { return }

        let needsReconnect = shares.contains {
            $0.autoMount && !isManuallyDisconnected($0.id) && !isMounted($0) && !isPendingMount($0.id)
        }

        for share in shares where share.autoMount && !isManuallyDisconnected(share.id) {
            if !isMounted(share) {
                mount(share)
            }
        }

        updateMountStatuses()

        if !needsReconnect {
            stopReconnectTimer()
        }
    }

    // MARK: - Host Resolution

    private enum ConfiguredHostType {
        case local(base: String)
        case plain(host: String)
        case ip(host: String)
    }

    private func baseHostName(from host: String) -> String {
        if host.contains("._smb._tcp") {
            return host.components(separatedBy: "._smb._tcp").first ?? host
        }
        if host.hasSuffix(".local") {
            return String(host.dropLast(6))
        }
        return host
    }

    private func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1 ||
               host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private func configuredHostType(for host: String) -> ConfiguredHostType {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("._smb._tcp.local") || normalized.hasSuffix(".local") {
            return .local(base: baseHostName(from: normalized))
        }
        if isIPAddress(normalized) {
            return .ip(host: normalized)
        }
        return .plain(host: normalized)
    }

    private func hostCandidates(for host: String) -> [String] {
        switch configuredHostType(for: host) {
        case .local(let base):
            return ["\(base).local", base]
        case .plain(let plain):
            return [plain]
        case .ip(let ip):
            return [ip]
        }
    }

    private func shouldKeepRetrying(_ share: SMBShare) -> Bool {
        guard isNetworkAvailable else { return false }
        guard !isManuallyDisconnected(share.id) else { return false }
        return shares.contains { $0.id == share.id }
    }

    @discardableResult
    private func waitRetry(for share: SMBShare, interval: TimeInterval = 0.35, until: Date? = nil) -> Bool {
        let slice: TimeInterval = 0.05
        var elapsed: TimeInterval = 0

        while elapsed < interval {
            if let until, Date() >= until { return false }
            if !shouldKeepRetrying(share) { return false }
            let remaining = interval - elapsed
            let sleepTime = min(slice, remaining)
            Thread.sleep(forTimeInterval: sleepTime)
            elapsed += sleepTime
        }

        if let until, Date() >= until { return false }
        return shouldKeepRetrying(share)
    }

    private func isSMBReachable(host: String, timeout: TimeInterval? = nil) -> Bool {
        let effectiveTimeout = timeout ?? smbReachabilityTimeout
        guard let port = NWEndpoint.Port(rawValue: 445) else { return false }

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reachable = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + effectiveTimeout)
        connection.cancel()
        return reachable
    }

    private func isBonjourAvailable(for serverName: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var found = false

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_smb._tcp", domain: "local"), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint,
                   name.lowercased() == serverName.lowercased() {
                    found = true
                    semaphore.signal()
                    break
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state {
                semaphore.signal()
            }
        }

        browser.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + bonjourQueryTimeout)
        browser.cancel()
        return found
    }

    private func stableReachability(for hosts: [String], share: SMBShare, until: Date) -> [String: Int] {
        var scores: [String: Int] = [:]
        while shouldKeepRetrying(share) && Date() < until {
            for host in hosts {
                if isSMBReachable(host: host) {
                    scores[host.lowercased(), default: 0] += 1
                }
            }
            if scores.values.contains(where: { $0 >= requiredStableSuccesses }) {
                break
            }
            if !waitRetry(for: share, interval: shortRetryInterval, until: until) {
                break
            }
        }
        return scores
    }

    private func isBonjourStable(base: String, share: SMBShare, until: Date) -> Bool {
        var successes = 0
        for i in 0..<bonjourCheckCycles {
            guard shouldKeepRetrying(share), Date() < until else { return false }
            if isBonjourAvailable(for: base) {
                successes += 1
                if successes >= requiredStableSuccesses {
                    return true
                }
            } else {
                successes = 0
            }

            if i < (bonjourCheckCycles - 1), !waitRetry(for: share, interval: shortRetryInterval, until: until) {
                return false
            }
        }
        return false
    }

    private func chooseMountHost(for share: SMBShare, until: Date) -> String? {
        let hostType = configuredHostType(for: share.host)

        switch hostType {
        case .plain(let host):
            let scores = stableReachability(for: [host], share: share, until: until)
            return (scores[host.lowercased()] ?? 0) >= requiredStableSuccesses ? host : nil

        case .ip(let host):
            let scores = stableReachability(for: [host], share: share, until: until)
            return (scores[host.lowercased()] ?? 0) >= requiredStableSuccesses ? host : nil

        case .local(let base):
            let localHost = "\(base).local"
            let plainHost = base
            let reachabilityScores = stableReachability(for: [localHost, plainHost], share: share, until: until)

            let localReachable = (reachabilityScores[localHost.lowercased()] ?? 0) >= requiredStableSuccesses
            let plainReachable = (reachabilityScores[plainHost.lowercased()] ?? 0) >= requiredStableSuccesses

            guard localReachable || plainReachable else { return nil }

            if isBonjourStable(base: base, share: share, until: until) {
                return "\(base)._smb._tcp.local"
            }
            if localReachable { return localHost }
            if plainReachable { return plainHost }
            return nil
        }
    }

    private func finalPreflight(share: SMBShare, selectedHost: String, until: Date) -> Bool {
        if selectedHost.contains("._smb._tcp.local") {
            let base = baseHostName(from: share.host)
            let localHost = "\(base).local"
            let plainHost = base

            guard isBonjourAvailable(for: base) else { return false }
            return isSMBReachable(host: localHost) || isSMBReachable(host: plainHost)
        }

        var successCount = 0
        while shouldKeepRetrying(share) && Date() < until {
            if isSMBReachable(host: selectedHost) {
                successCount += 1
                if successCount >= requiredStableSuccesses {
                    return true
                }
            }
            if !waitRetry(for: share, interval: shortRetryInterval, until: until) {
                return false
            }
        }
        return false
    }

    private func waitForSMBAvailability(for share: SMBShare) -> String? {
        guard shouldKeepRetrying(share) else { return nil }

        while shouldKeepRetrying(share) {
            let cycleDeadline = Date().addingTimeInterval(mountCycleTimeout)
            let resolutionDeadline = min(cycleDeadline, Date().addingTimeInterval(hostProbeWindow))

            if let selectedHost = chooseMountHost(for: share, until: resolutionDeadline),
               finalPreflight(share: share, selectedHost: selectedHost, until: cycleDeadline) {
                return selectedHost
            }

            if Date() >= cycleDeadline {
                continue
            }
            if !waitRetry(for: share, interval: shortRetryInterval, until: cycleDeadline) {
                if shouldKeepRetrying(share) {
                    continue
                }
                return nil
            }
        }

        return nil
    }

    // MARK: - Mount Status

    func isMounted(_ share: SMBShare) -> Bool {
        let baseHost: String
        if share.host.hasSuffix(".local") && !share.host.contains("._smb._tcp") {
            baseHost = String(share.host.dropLast(6)).lowercased()
        } else if share.host.contains("._smb._tcp") {
            baseHost = (share.host.components(separatedBy: "._smb._tcp").first ?? share.host).lowercased()
        } else {
            baseHost = share.host.lowercased()
        }
        let shareName = share.shareName.lowercased()

        let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLForRemountingKey],
            options: []
        ) ?? []

        for vol in vols {
            if let r = try? vol.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting {
                let s = r.absoluteString.lowercased()
                if s.contains("smb") && s.contains(baseHost) && s.contains(shareName) {
                    return true
                }
            }
        }
        return false
    }

    func updateMountStatuses() {
        DispatchQueue.main.async {
            for i in self.shares.indices {
                let mounted = self.isMounted(self.shares[i])
                if mounted && self.shares[i].status != .mounted {
                    self.shares[i].status = .mounted
                    self.shares[i].lastConnected = Date()
                    self.shares[i].lastError = nil
                } else if !mounted && self.shares[i].status == .mounted {
                    self.shares[i].status = .disconnected
                    self.shares[i].lastError = nil
                }
            }
            self.updateAppIcon()
        }
    }

    private func updateAppIcon() {
        let hasError = shares.contains { $0.status == .error || ($0.status == .disconnected && $0.autoMount) }
        DispatchQueue.main.async {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.updateStatusIcon(hasError: hasError)
            }
        }
    }

    // MARK: - Finder Mount

    private func runFinderMount(urlString: String) {
        let script = """
        try
            tell application "Finder"
                with timeout of \(finderAppleScriptTimeoutSeconds) seconds
                    mount volume "\(urlString)"
                end timeout
            end tell
        on error
        end try
        """

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardError = Pipe()
        task.standardOutput = Pipe()

        do {
            try task.run()

            let deadline = Date().addingTimeInterval(finderExecutionTimeout)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if task.isRunning {
                task.terminate()
            }

            task.waitUntilExit()
        } catch {
            return
        }
    }

    private func waitUntilMounted(_ share: SMBShare, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isMounted(share) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return isMounted(share)
    }

    // MARK: - Mount / Unmount

    func mount(_ share: SMBShare) {
        clearManuallyDisconnected(share.id)

        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        guard shares[idx].status != .mounted else { return }
        guard beginPendingMount(share.id) else { return }

        shares[idx].status = .connecting
        shares[idx].lastError = nil
        updateAppIcon()

        mountQueue.async {
            defer { self.endPendingMount(share.id) }
            self.performMount(for: share.id)
        }
    }

    private func performMount(for shareID: UUID) {
        guard let share = shares.first(where: { $0.id == shareID }) else { return }
        guard shouldKeepRetrying(share) else { return }

        guard let host = waitForSMBAvailability(for: share) else {
            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == shareID }) else { return }
                if self.isManuallyDisconnected(shareID) {
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = nil
                    self.clearExtraRetry(shareID)
                } else {
                    self.failCount[shareID, default: 0] += 1
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = "Host aktuell nicht erreichbar (SMB Port 445)."
                    self.scheduleOneExtraRetryIfNeeded(for: shareID)
                }
                self.updateAppIcon()
            }
            return
        }

        let password = KeychainHelper.shared.getPassword(for: shareID) ?? ""
        let urlString: String
        if !share.username.isEmpty && !password.isEmpty {
            let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            let encodedUser = share.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? share.username
            urlString = "smb://\(encodedUser):\(encodedPass)@\(host)/\(share.shareName)"
        } else if !share.username.isEmpty {
            let encodedUser = share.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? share.username
            urlString = "smb://\(encodedUser)@\(host)/\(share.shareName)"
        } else {
            urlString = "smb://\(host)/\(share.shareName)"
        }

        guard shouldKeepRetrying(share) else { return }
        runFinderMount(urlString: urlString)

        let mounted = waitUntilMounted(share, timeout: postMountVerifyTimeout)

        DispatchQueue.main.async {
            guard let idx = self.shares.firstIndex(where: { $0.id == shareID }) else { return }

            if self.isManuallyDisconnected(shareID) {
                self.shares[idx].status = .disconnected
                self.shares[idx].lastError = nil
                self.clearExtraRetry(shareID)
                self.updateAppIcon()
                return
            }

            if mounted {
                self.failCount[shareID] = nil
                self.clearExtraRetry(shareID)
                self.shares[idx].status = .mounted
                self.shares[idx].lastConnected = Date()
                self.shares[idx].lastError = nil
                self.sendNotification(title: "Connected", body: "\(self.shares[idx].name) successfully connected.")
            } else {
                self.failCount[shareID, default: 0] += 1
                self.shares[idx].status = .disconnected
                self.shares[idx].lastError = nil
                self.scheduleOneExtraRetryIfNeeded(for: shareID)
            }

            self.updateAppIcon()
        }
    }

    func unmount(_ share: SMBShare) {
        markManuallyDisconnected(share.id)
        endPendingMount(share.id)
        clearExtraRetry(share.id)
        failCount[share.id] = nil

        unmountQueue.async {
            for _ in 0..<6 {
                if !self.isMounted(share) {
                    break
                }
                let task = Process()
                task.launchPath = "/sbin/umount"
                task.arguments = [share.resolvedMountPoint]
                try? task.run()
                task.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.3)
            }

            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
                self.shares[idx].status = .disconnected
                self.shares[idx].lastError = nil
                self.updateAppIcon()
            }
        }
    }

    // MARK: - CRUD

    func addShare(_ share: SMBShare, password: String) {
        var s = share
        s.status = .disconnected
        shares.append(s)
        if !password.isEmpty {
            KeychainHelper.shared.savePassword(password, for: s.id)
        }
        saveShares()
        if s.autoMount {
            mount(s)
        }
    }

    func updateShare(_ share: SMBShare, password: String?) {
        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        let wasAutoMount = shares[idx].autoMount
        let wasMounted = isMounted(shares[idx])

        if wasMounted {
            unmount(shares[idx])
        }

        shares[idx] = share

        if let pwd = password, !pwd.isEmpty {
            KeychainHelper.shared.savePassword(pwd, for: share.id)
        }

        saveShares()

        if share.autoMount || (wasAutoMount && wasMounted) {
            mount(share)
        }
    }

    func removeShare(_ share: SMBShare) {
        if isMounted(share) {
            unmount(share)
        }
        clearManuallyDisconnected(share.id)
        endPendingMount(share.id)
        clearExtraRetry(share.id)
        failCount[share.id] = nil
        KeychainHelper.shared.deletePassword(for: share.id)
        shares.removeAll { $0.id == share.id }
        saveShares()
    }

    // MARK: - Helpers

    private func setError(for share: SMBShare, message: String) {
        DispatchQueue.main.async {
            guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
            self.shares[idx].status = .error
            self.shares[idx].lastError = message
            self.updateAppIcon()
        }
    }

    private func sendNotification(title: String, body: String) {
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
