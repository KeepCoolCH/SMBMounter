import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        setupMenuBar()
        ShareManager.shared.requestNotificationPermission()
        ShareManager.shared.startMonitoring()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        ShareManager.shared.stopMonitoring()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.autosaveName = "com.smbmounter.statusItem"
        
        if let button = statusItem?.button {
            button.image = menuBarIcon(systemSymbolName: "externaldrive.fill.badge.wifi")
            button.imagePosition = .imageOnly
            button.toolTip = "SMBMounter"
            button.setAccessibilityTitle("SMBMounter")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseDown])
        }
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(ShareManager.shared)
        )
        self.popover = popover
    }
    
    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        
        if let popover = popover {
            if popover.isShown {
                popover.close()
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func updateStatusIcon(hasError: Bool) {
        DispatchQueue.main.async {
            let symbolName = hasError ? "externaldrive.badge.exclamationmark" : "externaldrive.fill.badge.wifi"
            self.statusItem?.button?.image = self.menuBarIcon(systemSymbolName: symbolName)
        }
    }

    private func menuBarIcon(systemSymbolName: String) -> NSImage {
        if let symbol = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: "SMBMounter") {
            symbol.isTemplate = true
            return symbol
        }

        if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 18, height: 18)
            appIcon.isTemplate = false
            return appIcon
        }

        let fallback = NSImage(size: NSSize(width: 18, height: 18))
        fallback.lockFocus()
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 14, height: 12), xRadius: 2, yRadius: 2).fill()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: 10, width: 8, height: 3), xRadius: 1, yRadius: 1).fill()
        fallback.unlockFocus()
        fallback.isTemplate = true
        fallback.accessibilityDescription = "SMBMounter"
        return fallback
    }
}
