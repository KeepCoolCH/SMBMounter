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
    @State private var host: String = ""
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
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty
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
                        Text("Host / IP")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("192.168.1.100 or server.local", text: $host)
                    }
                    
                    HStack {
                        Text("Share Name")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("SharedFolder", text: $shareName)
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
                
                Section("Advanced") {
                    HStack {
                        Text("Mount Point")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("/Volumes/\(shareName.isEmpty ? "ShareName" : shareName)", text: $mountPoint)
                            .autocorrectionDisabled()
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
                
                // Preview
                if !host.isEmpty && !shareName.isEmpty {
                    Section("Preview") {
                        Text("smb://\(username.isEmpty ? "" : "\(username)@")\(host)/\(shareName)")
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
    }
    
    func loadExisting() {
        if case .edit(let share) = mode {
            name = share.name
            host = share.host
            shareName = share.shareName
            username = share.username
            mountPoint = share.mountPoint
            autoMount = share.autoMount
            password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        }
    }
    
    func save() {
        let displayName = name.isEmpty ? "\(host)/\(shareName)" : name
        
        switch mode {
        case .add:
            let share = SMBShare(
                name: displayName,
                host: host,
                shareName: shareName,
                username: username,
                mountPoint: mountPoint,
                autoMount: autoMount
            )
            onSave(share, password)
            
        case .edit(var share):
            share.name = displayName
            share.host = host
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
