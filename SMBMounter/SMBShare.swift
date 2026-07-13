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

enum ShareProtocol: String, Codable, CaseIterable, Identifiable {
    case smb = "SMB"
    case webdav = "WebDAV"

    var id: String { rawValue }

    var urlScheme: String {
        switch self {
        case .smb: return "smb"
        case .webdav: return "https"
        }
    }

    var displayName: String { rawValue }
}

enum WebDAVScheme: String, Codable, CaseIterable, Identifiable {
    case https = "HTTPS"
    case http = "HTTP"

    var id: String { rawValue }
    var urlScheme: String { rawValue.lowercased() }
    var defaultPort: Int { self == .http ? 80 : 443 }
}

struct SMBShare: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var connectionProtocol: ShareProtocol = .smb
    var webDAVScheme: WebDAVScheme = .https
    var host: String
    var port: Int = 0
    var shareName: String
    var username: String
    var mountPoint: String
    var autoMount: Bool = true
    var status: MountStatus = .disconnected
    var lastError: String? = nil
    var lastConnected: Date? = nil
    
    var connectionURL: String {
        "\(displayScheme)://\(displayHost)/\(shareName)"
    }
    
    var connectionURLWithUser: String {
        if username.isEmpty {
            return "\(displayScheme)://\(displayHost)/\(shareName)"
        }
        return "\(displayScheme)://\(username)@\(displayHost)/\(shareName)"
    }

    private var displayScheme: String {
        connectionProtocol == .webdav ? webDAVScheme.urlScheme : connectionProtocol.urlScheme
    }

    private var displayHost: String {
        guard connectionProtocol == .webdav,
              let components = URLComponents(string: host),
              components.scheme != nil,
              let parsedHost = components.host else {
            if connectionProtocol == .webdav, port > 0 {
                return "\(host):\(port)"
            }
            return host
        }

        let resolvedPort = port > 0 ? port : components.port
        if let resolvedPort {
            return "\(parsedHost):\(resolvedPort)"
        }
        return parsedHost
    }
    
    var resolvedMountPoint: String {
        if mountPoint.isEmpty {
            return "/Volumes/\(shareName)"
        }
        return mountPoint
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, connectionProtocol, webDAVScheme, host, port, shareName, username, mountPoint, autoMount
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        connectionProtocol = try container.decodeIfPresent(ShareProtocol.self, forKey: .connectionProtocol) ?? .smb
        webDAVScheme = try container.decodeIfPresent(WebDAVScheme.self, forKey: .webDAVScheme) ?? .https
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        shareName = try container.decode(String.self, forKey: .shareName)
        username = try container.decode(String.self, forKey: .username)
        mountPoint = try container.decode(String.self, forKey: .mountPoint)
        autoMount = try container.decode(Bool.self, forKey: .autoMount)
        status = .disconnected
    }
    
    init(name: String, connectionProtocol: ShareProtocol = .smb, webDAVScheme: WebDAVScheme = .https, host: String, port: Int = 0, shareName: String, username: String = "", mountPoint: String = "", autoMount: Bool = true) {
        self.name = name
        self.connectionProtocol = connectionProtocol
        self.webDAVScheme = webDAVScheme
        self.host = host
        self.port = port
        self.shareName = shareName
        self.username = username
        self.mountPoint = mountPoint
        self.autoMount = autoMount
    }
}
