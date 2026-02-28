import Foundation

enum MountStatus: String, Codable {
    case mounted = "Connected"
    case disconnected = "Disconnected"
    case connecting = "Connecting..."
    case error = "Error"
    
    var color: String {
        switch self {
        case .mounted: return "green"
        case .disconnected: return "gray"
        case .connecting: return "yellow"
        case .error: return "red"
        }
    }
    
    var systemImage: String {
        switch self {
        case .mounted: return "checkmark.circle.fill"
        case .disconnected: return "circle"
        case .connecting: return "arrow.clockwise.circle"
        case .error: return "exclamationmark.circle.fill"
        }
    }
}

struct SMBShare: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var shareName: String
    var username: String
    var mountPoint: String
    var autoMount: Bool = true
    var status: MountStatus = .disconnected
    var lastError: String? = nil
    var lastConnected: Date? = nil
    
    var smbURL: String {
        "smb://\(host)/\(shareName)"
    }
    
    var smbURLWithUser: String {
        if username.isEmpty {
            return "smb://\(host)/\(shareName)"
        }
        return "smb://\(username)@\(host)/\(shareName)"
    }
    
    var resolvedMountPoint: String {
        if mountPoint.isEmpty {
            return "/Volumes/\(shareName)"
        }
        return mountPoint
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, host, shareName, username, mountPoint, autoMount
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        shareName = try container.decode(String.self, forKey: .shareName)
        username = try container.decode(String.self, forKey: .username)
        mountPoint = try container.decode(String.self, forKey: .mountPoint)
        autoMount = try container.decode(Bool.self, forKey: .autoMount)
        status = .disconnected
    }
    
    init(name: String, host: String, shareName: String, username: String = "", mountPoint: String = "", autoMount: Bool = true) {
        self.name = name
        self.host = host
        self.shareName = shareName
        self.username = username
        self.mountPoint = mountPoint
        self.autoMount = autoMount
    }
}
