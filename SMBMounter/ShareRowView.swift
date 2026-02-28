import SwiftUI

struct ShareRowView: View {
    @Binding var share: SMBShare
    @EnvironmentObject var manager: ShareManager
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(share.name)
                        .font(.headline)
                    if share.autoMount {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .help("Auto-Mount active")
                    }
                }
                
                Text(share.smbURL)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let error = share.lastError, share.status == .error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else if let date = share.lastConnected, share.status == .mounted {
                    Text("Connected since \(date.formatted(.dateTime.hour().minute()))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text(share.status.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusBackground)
                .cornerRadius(10)
            
            Button {
                if manager.isMounted(share) {
                    manager.unmount(share)
                } else {
                    manager.mount(share)
                }
            } label: {
                Image(systemName: manager.isMounted(share) ? "eject.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(manager.isMounted(share) ? .orange : .accentColor)
            }
            .buttonStyle(.plain)
            .help(manager.isMounted(share) ? "Disconnect" : "Connect")
            .disabled(share.status == .connecting)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder
    var statusIcon: some View {
        switch share.status {
        case .mounted:
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .foregroundColor(.green)
        case .disconnected:
            Image(systemName: "externaldrive.badge.minus")
                .foregroundColor(.secondary)
        case .connecting:
            ProgressView()
                .scaleEffect(0.6)
        case .error:
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundColor(.red)
        }
    }
    
    var statusBackground: Color {
        switch share.status {
        case .mounted: return Color.green.opacity(0.15)
        case .disconnected: return Color.secondary.opacity(0.1)
        case .connecting: return Color.yellow.opacity(0.15)
        case .error: return Color.red.opacity(0.15)
        }
    }
}
