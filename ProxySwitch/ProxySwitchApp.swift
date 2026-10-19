import SwiftUI
import Combine

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
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let appState = AppState.shared
    var settingsWindow: NSWindow?
    private var speedCancellable: AnyCancellable?
    private var menuBarCancellables = Set<AnyCancellable>()
    private var lastMenuBarSymbol: String?
    private var lastMenuBarColor: NSColor?
    private var globalEventMonitor: Any?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: on macOS 26+ the scene-backed status item can
        // crash (over-release inside AppKit) when a second instance of the same
        // app registers its status item while another instance is still alive.
        // An flock lock survives forks (the status-item scene child inherits the
        // open file description), so it won't false-trigger on that child.
        if !acquireInstanceLock() {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                .activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }

        setupMenuBar()
        setupPopover()
        configureAppAppearance()
        observeTrafficSpeed()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSettings,
            object: nil
        )
    }

    /// Acquires the single-instance lock. Returns false if another live
    /// instance already holds it. The lock fd is intentionally never closed.
    private func acquireInstanceLock() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ProxySwitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
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
            updateMenuBarAppearance()
        }
    }

    /// Updates the menu bar icon image, color, and title based on current state.
    /// Uses caching to avoid redundant updates that can trigger AppKit layout animations.
    private func updateMenuBarAppearance() {
        guard let button = statusItem.button else { return }

        let symbolName = appState.menuBarIconName
        let color = appState.menuBarIconColor
        let anyProxyEnabled = appState.systemProxyEnabled || appState.terminalProxyEnabled
        let newTitle: String
        if anyProxyEnabled, let speed = appState.trafficSpeed, speed > 0 {
            newTitle = " " + speed.trafficMenuBarString
        } else {
            newTitle = ""
        }

        // Only mutate UI if something actually changed — avoids AppKit animation crashes.
        let currentTitle = button.title
        let needsImageUpdate = !imageMatches(symbolName: symbolName, color: color)
        let needsTitleUpdate = currentTitle != newTitle

        guard needsImageUpdate || needsTitleUpdate else { return }

        // Disable implicit animations during the update.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if needsImageUpdate {
            var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ProxySwitch")
            image?.size = NSSize(width: 18, height: 18)
            if let color = color {
                image = image?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [color])
                )
            }
            button.image = image
            lastMenuBarSymbol = symbolName
            lastMenuBarColor = color
        }

        if needsTitleUpdate {
            button.title = newTitle
        }

        CATransaction.commit()
    }

    /// Checks whether the current button image matches the desired symbol and color.
    private func imageMatches(symbolName: String, color: NSColor?) -> Bool {
        let colorChanged = (lastMenuBarColor == nil && color != nil)
            || (lastMenuBarColor != nil && color == nil)
            || (lastMenuBarColor != nil && color != nil && !lastMenuBarColor!.isEqual(color!))
        guard lastMenuBarSymbol == symbolName, !colorChanged else { return false }
        return true
    }

    // MARK: Traffic Speed Observation

    private func observeTrafficSpeed() {
        // Listen to traffic speed changes
        speedCancellable = appState.$trafficSpeed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarAppearance()
            }

        // Also update appearance when proxy health or enabled state changes (affects icon color)
        appState.$proxyHealth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarAppearance()
            }
            .store(in: &menuBarCancellables)

        appState.$systemProxyEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarAppearance()
            }
            .store(in: &menuBarCancellables)

        appState.$terminalProxyEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarAppearance()
            }
            .store(in: &menuBarCancellables)
    }

    // MARK: Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSHostingView(
            rootView: PopoverView()
                .environmentObject(appState)
        )
        popover.contentViewController?.view.frame = NSSize(width: 280, height: 400).toCGRect()
    }

    // MARK: NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        appState.setPopoverVisible(true)
        startGlobalEventMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        appState.setPopoverVisible(false)
        stopGlobalEventMonitor()
    }

    /// Closes the popover when the user clicks outside of it (including on other apps' windows).
    /// Clicks on the status bar item are ignored so that `statusBarClicked` can toggle the popover.
    private func startGlobalEventMonitor() {
        stopGlobalEventMonitor()
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            if let statusWindow = self.statusItem.button?.window,
               statusWindow.frame.contains(NSEvent.mouseLocation) {
                return
            }
            self.closePopover()
        }
    }

    private func stopGlobalEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(withTitle: "v\(version)", action: nil, keyEquivalent: "")
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
                // Activate the app so a .transient popover closes reliably when
                // the user clicks another window.
                NSApp.activate(ignoringOtherApps: true)
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
            // Workaround for a macOS 26/27 crash: the scene-backed status item
            // over-releases when a settings window closes during a
            // .regular <-> .accessory activation-policy transition, and when a
            // restorable window comes back / a closed window deallocs.
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
        }

        // Activate so the window can take key status. Deliberately keep the
        // app at `.accessory`: toggling the activation policy around the
        // settings window lifecycle is what trips the AppKit over-release.
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSWindowDelegate

    /// Keep the window alive on close (`isReleasedWhenClosed = false`) and
    /// keep `.accessory` — no activation-policy churn (see `showSettingsWindow`).
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == settingsWindow else { return }
        window.orderOut(nil)
    }

    // MARK: Quit

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Appearance

    /// The app is a menu-bar-only utility; keep it at `.accessory` (no Dock icon).
    private func configureAppAppearance() {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Helper

extension NSSize {
    func toCGRect() -> NSRect {
        NSRect(x: 0, y: 0, width: width, height: height)
    }
}
