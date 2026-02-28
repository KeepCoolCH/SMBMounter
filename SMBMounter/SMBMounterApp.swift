import SwiftUI

@main
struct SMBMounterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            ContentView()
                .environmentObject(ShareManager.shared)
        }
    }
}
