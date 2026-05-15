import SwiftUI

// MARK: - App Entry Point

/// Menu-bar-only app. The SwiftUI `body` is an empty Settings scene;
/// the real UI lives in `AppDelegate` using `NSStatusBar` + `NSPopover`.
@main
struct ProxySwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

/// Manages the status bar item, popover, and settings window lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    let appState = AppState.shared
    var settingsWindow: NSWindow?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPopover()
        configureAppAppearance()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSettings,
            object: nil
        )
    }

    // MARK: Menu Bar

    private func setupMenuBar() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "ProxySwitch")
            button.image?.size = NSSize(width: 18, height: 18)
            button.action = #selector(statusBarClicked)
            button.target = self
            // Handle both left-click (popover) and right-click (context menu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSHostingView(
            rootView: PopoverView()
                .environmentObject(appState)
        )
        popover.contentViewController?.view.frame = NSSize(width: 280, height: 400).toCGRect()
    }

    // MARK: Click Handling

    @objc private func statusBarClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            togglePopover()
        }
    }

    /// Right-click context menu with bulk actions, settings, and quit.
    private func showRightClickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "开启全部代理", action: #selector(enableAllProxy), keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部代理", action: #selector(disableAllProxy), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ProxySwitch", action: #selector(quitApp), keyEquivalent: "q")

        guard let button = statusItem.button else { return }
        let point = NSPoint(x: 0, y: button.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: Bulk Actions

    @objc private func enableAllProxy() {
        Task { @MainActor in
            appState.enableAll()
        }
    }

    @objc private func disableAllProxy() {
        Task { @MainActor in
            appState.disableAll()
        }
    }

    // MARK: Settings Window

    /// Manually managed settings window (not SwiftUI Settings scene),
    /// because `.accessory` mode apps can't reliably use `sendAction("showSettingsWindow:")`.
    @objc private func openSettings() {
        showSettingsWindow()
    }

    @objc private func handleOpenSettings() {
        closePopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showSettingsWindow()
        }
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let hostingView = NSHostingView(rootView: SettingsView())
            hostingView.frame = NSRect(x: 0, y: 0, width: 450, height: 350)

            let window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.title = "ProxySwitch 设置"
            window.center()
            window.delegate = self
            settingsWindow = window
        }

        // Bring to front when in menu-bar-only mode.
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSWindowDelegate

    /// Revert to `.accessory` (no Dock icon) when settings window closes,
    /// unless the user explicitly opted in via "showInDock".
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == settingsWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !UserDefaults.standard.bool(forKey: "showInDock") {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: Quit

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Appearance

    /// Reads the "showInDock" preference and sets the initial activation policy.
    private func configureAppAppearance() {
        UserDefaults.standard.register(defaults: ["showInDock": false])
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Helper

extension NSSize {
    func toCGRect() -> NSRect {
        NSRect(x: 0, y: 0, width: width, height: height)
    }
}
