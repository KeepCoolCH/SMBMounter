import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: ShareManager
    @State private var showAddSheet = false
    @State private var editingShare: SMBShare? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.fill.badge.wifi")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("SMBMounter")
                    .font(.headline)
                Spacer()
                Button {
                    manager.mountAllAutoShares()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Connect all Auto-Shares")
                
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Add Share")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            if manager.shares.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.wifi")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No shares configured")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Click + to add an SMB share")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Share") {
                        showAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach($manager.shares) { $share in
                        ShareRowView(share: $share)
                            .contextMenu {
                                Button("Edit") { editingShare = share }
                                Divider()
                                Button("Connect now") { manager.mount(share) }
                                Button("Disconnect") { manager.unmount(share) }
                                Divider()
                                Button("Open in Finder") { openInFinder(share) }
                                Divider()
                                Button("Delete", role: .destructive) { manager.removeShare(share) }
                            }
                    }
                    .onDelete { indices in
                        indices.forEach { manager.removeShare(manager.shares[$0]) }
                    }
                }
                .listStyle(.plain)
            }
            
            Divider()
            
            HStack {
                Circle()
                    .fill(overallStatusColor)
                    .frame(width: 8, height: 8)
                Text(overallStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 400, height: 480)
        .sheet(isPresented: $showAddSheet) {
            ShareEditView(mode: .add) { share, password in
                manager.addShare(share, password: password)
            }
        }
        .sheet(item: $editingShare) { share in
            ShareEditView(mode: .edit(share)) { updatedShare, password in
                manager.updateShare(updatedShare, password: password)
            }
        }
        .onAppear {
            manager.requestNotificationPermission()
            manager.updateMountStatuses()
        }
    }
    
    var overallStatusColor: Color {
        if manager.shares.allSatisfy({ $0.status == .mounted || !$0.autoMount }) { return .green }
        if manager.shares.contains(where: { $0.status == .error }) { return .red }
        if manager.shares.contains(where: { $0.status == .connecting }) { return .yellow }
        return .orange
    }
    
    var overallStatusText: String {
        let mounted = manager.shares.filter { $0.status == .mounted }.count
        let total = manager.shares.count
        return "\(mounted)/\(total) connected"
    }
    
    func openInFinder(_ share: SMBShare) {
        NSWorkspace.shared.open(URL(fileURLWithPath: share.resolvedMountPoint))
    }
}
