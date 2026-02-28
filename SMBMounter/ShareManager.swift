import Foundation
import Combine
import AppKit
import Network
import UserNotifications

class ShareManager: ObservableObject {
    static let shared = ShareManager()
    
    @Published var shares: [SMBShare] = []
    
    private var manuallyDisconnected: Set<UUID> = []
    
    private var monitorTimer: Timer?
    private var pathMonitors: [UUID: NWPathMonitor] = [:]
    private let monitorQueue = DispatchQueue(label: "com.smbmounter.monitor", qos: .background)
    private let reconnectInterval: TimeInterval = 15
    private var isNetworkAvailable: Bool = true
    private var networkMonitor: NWPathMonitor?
    
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
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isNetworkAvailable = available
                if available {
                    self?.mountAllAutoShares()
                }
            }
        }
        nm.start(queue: monitorQueue)
        networkMonitor = nm
        
        monitorTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.mountAllAutoShares()
        }
    }
    
    func stopMonitoring() {
        monitorTimer?.invalidate()
        networkMonitor?.cancel()
    }
    
    private func checkAndReconnect() {
        guard isNetworkAvailable else { return }
        
        for share in shares where share.autoMount {
            guard !manuallyDisconnected.contains(share.id) else { continue }
            if !isMounted(share) {
                mount(share)
            }
        }
        updateMountStatuses()
    }
    
    func mountAllAutoShares() {
        for share in shares where share.autoMount {
            // Skip shares that were manually disconnected
            guard !manuallyDisconnected.contains(share.id) else { continue }
            if !isMounted(share) {
                mount(share)
            }
        }
        updateMountStatuses()
    }
    
    // MARK: - Mount Status
    
    func isMounted(_ share: SMBShare) -> Bool {
        let host = share.host.lowercased()
        let shareName = share.shareName.lowercased()
        
        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeURLForRemountingKey],
            options: []
        ) ?? []
        
        for volumeURL in mountedVolumes {
            if let remountURL = try? volumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting {
                let remount = remountURL.absoluteString.lowercased()
                if remount.contains("smb") && remount.contains(host) && remount.contains(shareName) {
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
                }
            }
            self.updateAppIcon()
        }
    }
    
    private func updateAppIcon() {
        let hasError = shares.contains { $0.status == .error || $0.status == .disconnected && $0.autoMount }
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.updateStatusIcon(hasError: hasError)
        }
    }
    
    // MARK: - Mount / Unmount
    
    func mount(_ share: SMBShare) {
        manuallyDisconnected.remove(share.id)
        
        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        DispatchQueue.main.async {
            self.shares[idx].status = .connecting
        }
        monitorQueue.async {
            self.performMount(share)
        }
    }
    
    private func performMount(_ share: SMBShare) {
        let password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        
        var urlString: String
        if !share.username.isEmpty && !password.isEmpty {
            let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            let encodedUser = share.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? share.username
            urlString = "smb://\(encodedUser):\(encodedPass)@\(share.host)/\(share.shareName)"
        } else if !share.username.isEmpty {
            urlString = "smb://\(share.username)@\(share.host)/\(share.shareName)"
        } else {
            urlString = "smb://\(share.host)/\(share.shareName)"
        }
        
        let script = "tell application \"Finder\" to mount volume \"\(urlString)\""
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            Thread.sleep(forTimeInterval: 1.5)
            
            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
                
                if task.terminationStatus == 0 || self.isMounted(self.shares[idx]) {
                    self.shares[idx].status = .mounted
                    self.shares[idx].lastConnected = Date()
                    self.shares[idx].lastError = nil
                    self.sendNotification(title: "Connected", body: "\(share.name) successfully connected.")
                } else {
                    let msg = errorOutput.isEmpty ? "Connection error (Code \(task.terminationStatus))" : errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.shares[idx].status = .error
                    self.shares[idx].lastError = msg
                }
                self.updateAppIcon()
            }
        } catch {
            setError(for: share, message: error.localizedDescription)
        }
    }
    
    func unmount(_ share: SMBShare) {
        manuallyDisconnected.insert(share.id)
        
        monitorQueue.async {
            let task = Process()
            task.launchPath = "/sbin/umount"
            task.arguments = [share.resolvedMountPoint]
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {}
            
            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
                self.shares[idx].status = .disconnected
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
        manuallyDisconnected.remove(share.id)
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
