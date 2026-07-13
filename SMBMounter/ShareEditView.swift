import SwiftUI

enum EditMode {
    case add
    case edit(SMBShare)
}

struct ShareEditView: View {
    let mode: EditMode
    let onSave: (SMBShare, String) -> Void
    
    @Environment(\.dismiss) var dismiss
    
    @State private var name: String = ""
    @State private var connectionProtocol: ShareProtocol = .smb
    @State private var webDAVScheme: WebDAVScheme = .https
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var mountPoint: String = ""
    @State private var autoMount: Bool = true
    @State private var showPassword: Bool = false
    
    var title: String {
        switch mode {
        case .add: return "Add Share"
        case .edit: return "Edit Share"
        }
    }
    
    var saveEnabled: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty &&
        portIsValid
    }

    var portIsValid: Bool {
        guard connectionProtocol == .webdav else { return true }
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed) else { return false }
        return (1...65535).contains(value)
    }
    
    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding()
            
            Divider()
            
            Form {
                Section("General") {
                    HStack {
                        Text("Name")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("My Network Drive", text: $name)
                    }
                    
                    HStack {
                        Text("Protocol")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Picker("", selection: $connectionProtocol) {
                            ForEach(ShareProtocol.allCases) { shareProtocol in
                                Text(shareProtocol.displayName).tag(shareProtocol)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("Host / IP")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("192.168.1.100 or server.local", text: $host)
                    }

                    if connectionProtocol == .webdav {
                        HStack {
                            Text("WebDAV")
                                .frame(width: 100, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Picker("", selection: $webDAVScheme) {
                                ForEach(WebDAVScheme.allCases) { scheme in
                                    Text(scheme.rawValue).tag(scheme)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }

                        HStack {
                            Text("Port")
                                .frame(width: 100, alignment: .trailing)
                                .foregroundColor(.secondary)
                            TextField("443", text: $port)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    
                    HStack {
                        Text("Share Name")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("SharedFolder", text: $shareName)
                    }
                    
                    HStack {
                        Text("Mount Point")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Text(mountPoint.isEmpty ? "/Volumes/\(shareName.isEmpty ? "ShareName" : shareName)" : mountPoint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    
                    HStack {
                        Text("Auto-Mount")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Toggle("", isOn: $autoMount)
                            .labelsHidden()
                        Text("Automatically connect and reconnect on disconnect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Credentials (optional)") {
                    HStack {
                        Text("Username")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("domain\\user or user", text: $username)
                            .autocorrectionDisabled()
                    }
                    
                    HStack {
                        Text("Password")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        if showPassword {
                            TextField("Password", text: $password)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Password", text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                    
                    Text("The password is securely stored in the macOS Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !host.isEmpty && !shareName.isEmpty {
                    Section("Preview") {
                        Text(previewURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!saveEnabled)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 500, height: 540)
        .onAppear(perform: loadExisting)
        .onChange(of: connectionProtocol) { _, newValue in
            if newValue == .webdav && port.trimmingCharacters(in: .whitespaces).isEmpty {
                port = defaultWebDAVPort
            }
        }
        .onChange(of: webDAVScheme) { oldValue, newValue in
            let trimmed = port.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "\(oldValue.defaultPort)" {
                port = "\(newValue.defaultPort)"
            }
        }
    }
    
    func loadExisting() {
        if case .edit(let share) = mode {
            name = share.name
            connectionProtocol = share.connectionProtocol
            webDAVScheme = share.webDAVScheme
            host = share.host
            port = share.port > 0 ? "\(share.port)" : (share.connectionProtocol == .webdav ? defaultWebDAVPort : "")
            shareName = share.shareName
            username = share.username
            mountPoint = share.mountPoint
            autoMount = share.autoMount
            password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        }
    }

    var previewURL: String {
        let scheme: String
        let displayHost: String

        scheme = connectionProtocol == .webdav ? webDAVScheme.urlScheme : connectionProtocol.urlScheme
        displayHost = connectionProtocol == .webdav ? "\(cleanHost):\(effectiveWebDAVPort)" : cleanHost

        return "\(scheme)://\(username.isEmpty ? "" : "\(username)@")\(displayHost)/\(shareName)"
    }

    var effectiveWebDAVPort: Int {
        Int(port.trimmingCharacters(in: .whitespaces)) ?? Int(defaultWebDAVPort) ?? 443
    }

    var defaultWebDAVPort: String {
        "\(webDAVScheme.defaultPort)"
    }

    var cleanHost: String {
        guard connectionProtocol == .webdav,
              let components = URLComponents(string: host),
              components.scheme != nil,
              let parsedHost = components.host else {
            return host
        }
        return parsedHost
    }
    
    func save() {
        let displayName = name.isEmpty ? "\(host)/\(shareName)" : name
        
        switch mode {
        case .add:
            let share = SMBShare(
                name: displayName,
                connectionProtocol: connectionProtocol,
                webDAVScheme: webDAVScheme,
                host: host,
                port: connectionProtocol == .webdav ? effectiveWebDAVPort : 0,
                shareName: shareName,
                username: username,
                mountPoint: mountPoint,
                autoMount: autoMount
            )
            onSave(share, password)
            
        case .edit(var share):
            share.name = displayName
            share.connectionProtocol = connectionProtocol
            share.webDAVScheme = webDAVScheme
            share.host = host
            share.port = connectionProtocol == .webdav ? effectiveWebDAVPort : 0
            share.shareName = shareName
            share.username = username
            share.mountPoint = mountPoint
            share.autoMount = autoMount
            onSave(share, password)
        }
    }
}

#Preview {
    ShareEditView(mode: .add) { _, _ in }
}
