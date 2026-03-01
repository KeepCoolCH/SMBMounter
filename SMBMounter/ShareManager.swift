import Foundation
import Combine
import AppKit
import Network
import UserNotifications

class ShareManager: ObservableObject {
    static let shared = ShareManager()
    
    @Published var shares: [SMBShare] = []
    
    private var manuallyDisconnected: Set<UUID> = []
    private var failCount: [UUID: Int] = [:]
    
    private let mountQueue = DispatchQueue(label: "com.smbmounter.mount", qos: .background)
    private let monitorQueue = DispatchQueue(label: "com.smbmounter.monitor", qos: .background)
    
    private var monitorTimer: Timer?
    private var recoveryTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var isNetworkAvailable: Bool = false
    private var networkRecoveryRetries: Int = 0
    private let maxRecoveryRetries = 8
    private let reconnectInterval: TimeInterval = 15
    
    private init() {
        loadShares()
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
        let nm = NWPathMonitor()
        nm.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = available
                if available && !wasAvailable {
                    self.startRecoveryRetries()
                } else if !available {
                    self.stopRecoveryRetries()
                    self.setAllDisconnectedSilently()
                }
            }
        }
        nm.start(queue: monitorQueue)
        networkMonitor = nm
        
        monitorTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isNetworkAvailable = true
            self.mountAllAutoShares()
        }
    }
    
    func stopMonitoring() {
        monitorTimer?.invalidate()
        recoveryTimer?.invalidate()
        networkMonitor?.cancel()
    }
    
    // MARK: - Recovery
    
    private func startRecoveryRetries() {
        stopRecoveryRetries()
        networkRecoveryRetries = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.mountAllAutoShares()
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.networkRecoveryRetries += 1
            self.mountAllAutoShares()
            if self.networkRecoveryRetries >= self.maxRecoveryRetries {
                self.stopRecoveryRetries()
            }
        }
    }
    
    private func stopRecoveryRetries() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        networkRecoveryRetries = 0
    }
    
    private func setAllDisconnectedSilently() {
        for i in shares.indices where shares[i].status != .disconnected {
            shares[i].status = .disconnected
            shares[i].lastError = nil
        }
        failCount = [:]
        updateAppIcon()
    }
    
    private func checkAndReconnect() {
        guard isNetworkAvailable else { return }
        mountAllAutoShares()
        updateMountStatuses()
    }
    
    func mountAllAutoShares() {
        for share in shares where share.autoMount && !manuallyDisconnected.contains(share.id) {
            if !isMounted(share) && share.status != .connecting {
                mount(share)
            }
        }
        updateMountStatuses()
    }
    
    // MARK: - Bonjour check
    
    private func isBonjourAvailable(for serverName: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_smb._tcp", domain: "local"), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    if name.lowercased() == serverName.lowercased() {
                        found = true
                        semaphore.signal()
                    }
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { semaphore.signal() }
        }
        browser.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + 3.0)
        browser.cancel()
        return found
    }
    
    // MARK: - Host candidates
    
    private func hostCandidates(for host: String) -> [String] {
        if host.hasSuffix(".local") && !host.contains("._smb._tcp") {
            let name = String(host.dropLast(6))
            return ["\(name)._smb._tcp.local", "\(name).local", name]
        }
        if host.contains("._smb._tcp") {
            let plain = host.components(separatedBy: "._smb._tcp").first ?? host
            return [host, plain]
        }
        return [host]
    }
    
    private func resolvedHost(for share: SMBShare) -> String {
        let candidates = hostCandidates(for: share.host)
        let failures = failCount[share.id] ?? 0
        let attemptsPerCandidate = 2
        var index = min(failures / attemptsPerCandidate, candidates.count - 1)
        
        if index == 0 && candidates[0].contains("._smb._tcp") && failures == 0 {
            let serverName = String(share.host.hasSuffix(".local") ? share.host.dropLast(6) : Substring(share.host))
            if !isBonjourAvailable(for: serverName) {
                index = 1
                failCount[share.id] = attemptsPerCandidate
            }
        }
        
        return candidates[min(index, candidates.count - 1)]
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
            includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []
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
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.updateStatusIcon(hasError: hasError)
        }
    }
    
    // MARK: - Mount / Unmount
    
    func mount(_ share: SMBShare) {
        manuallyDisconnected.remove(share.id)
        
        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        guard shares[idx].status != .connecting && shares[idx].status != .mounted else { return }
        
        shares[idx].status = .connecting
        updateAppIcon()
        
        mountQueue.async {
            self.performMount(share)
        }
    }
    
    private func performMount(_ share: SMBShare) {
        let password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        let host = resolvedHost(for: share)
        
        var urlString: String
        if !share.username.isEmpty && !password.isEmpty {
            let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            let encodedUser = share.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? share.username
            urlString = "smb://\(encodedUser):\(encodedPass)@\(host)/\(share.shareName)"
        } else if !share.username.isEmpty {
            urlString = "smb://\(share.username)@\(host)/\(share.shareName)"
        } else {
            urlString = "smb://\(host)/\(share.shareName)"
        }
        
        let script = """
        try
            tell application "Finder"
                with timeout of 10 seconds
                    mount volume "\(urlString)"
                end timeout
            end tell
        on error
        end try
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            Thread.sleep(forTimeInterval: 1.5)
            
            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
                
                if self.isMounted(self.shares[idx]) {
                    self.failCount[share.id] = nil
                    self.shares[idx].status = .mounted
                    self.shares[idx].lastConnected = Date()
                    self.shares[idx].lastError = nil
                    self.sendNotification(title: "Connected", body: "\(share.name) successfully connected.")
                } else {
                    let current = self.failCount[share.id] ?? 0
                    let candidates = self.hostCandidates(for: share.host)
                    let maxCount = (candidates.count * 2) - 1
                    if current < maxCount {
                        self.failCount[share.id] = current + 1
                    }
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = nil
                }
                self.updateAppIcon()
            }
        } catch {
            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
                self.shares[idx].status = .error
                self.shares[idx].lastError = error.localizedDescription
                self.updateAppIcon()
            }
        }
    }
    
    func unmount(_ share: SMBShare) {
        manuallyDisconnected.insert(share.id)
        failCount[share.id] = nil
        
        mountQueue.async {
            let task = Process()
            task.launchPath = "/sbin/umount"
            task.arguments = [share.resolvedMountPoint]
            try? task.run()
            task.waitUntilExit()
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
        if !password.isEmpty { KeychainHelper.shared.savePassword(password, for: s.id) }
        saveShares()
        if s.autoMount { mount(s) }
    }
    
    func updateShare(_ share: SMBShare, password: String?) {
        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        let wasAutoMount = shares[idx].autoMount
        let wasMounted = isMounted(shares[idx])
        if wasMounted { unmount(shares[idx]) }
        shares[idx] = share
        if let pwd = password, !pwd.isEmpty { KeychainHelper.shared.savePassword(pwd, for: share.id) }
        saveShares()
        if share.autoMount || (wasAutoMount && wasMounted) { mount(share) }
    }
    
    func removeShare(_ share: SMBShare) {
        if isMounted(share) { unmount(share) }
        manuallyDisconnected.remove(share.id)
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
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }
    
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
