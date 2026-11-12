// CloseQuit — quit a macOS app when you close its last window with the red X button.
//
// How it works:
//   1. A passive (listen-only) event tap watches left mouse clicks system-wide.
//   2. On mouse-down, the Accessibility API identifies the element under the cursor.
//      If it is a window's close button (subrole "AXCloseButton"), the click is remembered.
//   3. On mouse-up inside that button, the click goes through normally and the window closes.
//      CloseQuit then checks the app a few times over ~1.75 s. If the app has no
//      standard windows or dialogs left, it asks the app to quit (a normal Quit,
//      so apps still get a chance to save or prompt).
//
// Because the click is never blocked, "Save changes?" sheets work as usual: the
// window stays open while the sheet is up, so the app is not quit.
//
// Hold Shift while clicking the X to just close the window without quitting.

import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: State

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var pending: PendingClick?
    private var lastFrontApp: NSRunningApplication?
    private let systemWide = AXUIElementCreateSystemWide()
    private let defaults = UserDefaults.standard

    private struct PendingClick {
        let pid: pid_t
        let buttonFrame: CGRect?
    }

    /// Apps that should never be quit this way.
    private static let alwaysExcluded: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
    ]

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled"); updateIcon() }
    }

    private var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "excluded") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        AXUIElementSetMessagingTimeout(systemWide, 0.3)

        lastFrontApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.lastFrontApp = app
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            startEventTap()
        } else {
            waitForPermission()
        }
    }

    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.startEventTap()
                self?.updateIcon()
            }
        }
    }

    // MARK: Event tap

    private func startEventTap() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    me.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            NSLog("CloseQuit: could not create event tap (Accessibility permission missing?)")
            waitForPermission()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }

        case .leftMouseDown:
            pending = nil
            guard enabled, !event.flags.contains(.maskShift) else { return }
            pending = closeButtonClick(at: event.location)

        case .leftMouseUp:
            guard let click = pending else { return }
            pending = nil
            // Only count it if the mouse was released over the button (user didn't drag away).
            if let frame = click.buttonFrame, !frame.insetBy(dx: -4, dy: -4).contains(event.location) {
                return
            }
            quitIfNoWindowsLeft(pid: click.pid)

        default:
            break
        }
    }

    /// Returns a pending click if the point is over a close button of a quittable app.
    private func closeButtonClick(at point: CGPoint) -> PendingClick? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        // The hit may be the button itself or a child of it.
        var button: AXUIElement?
        if isCloseButton(hit) {
            button = hit
        } else if let parent: AXUIElement = axAttribute(hit, "AXParent"), isCloseButton(parent) {
            button = parent
        }
        guard let button else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(button, &pid) == .success, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return nil }

        if let bundleID = app.bundleIdentifier,
           Self.alwaysExcluded.contains(bundleID) || excluded.contains(bundleID) {
            return nil
        }

        return PendingClick(pid: pid, buttonFrame: axFrame(button))
    }

    private func isCloseButton(_ element: AXUIElement) -> Bool {
        (axAttribute(element, "AXSubrole") as String?) == "AXCloseButton"
    }

    // MARK: Quitting

    /// Checks a few times (windows take a moment to close/animate) and quits once none remain.
    private func quitIfNoWindowsLeft(pid: pid_t, attempt: Int = 0) {
        let delays: [Double] = [0.25, 0.5, 1.0]
        guard attempt < delays.count else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self,
                  let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated else { return }

            switch self.windowCount(pid: pid) {
            case .some(0):
                app.terminate()
            case .none:
                return // Couldn't read the app's windows — play it safe and do nothing.
            default:
                self.quitIfNoWindowsLeft(pid: pid, attempt: attempt + 1)
            }
        }
    }

    /// Number of real windows (standard windows and dialogs, incl. minimised ones), or nil if unreadable.
    private func windowCount(pid: pid_t) -> Int? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let windows: [AXUIElement] = axAttribute(appElement, "AXWindows") else { return nil }

        let counted: Set<String> = ["AXStandardWindow", "AXDialog", "AXSystemDialog"]
        return windows.filter { window in
            guard let subrole: String = axAttribute(window, "AXSubrole") else { return false }
            return counted.contains(subrole)
        }.count
    }

    // MARK: Accessibility helpers

    private func axAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    // MARK: Menu bar

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = enabled && AXIsProcessTrusted()
        let image = NSImage(systemSymbolName: active ? "xmark.circle.fill" : "xmark.circle",
                            accessibilityDescription: "CloseQuit")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !active
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "Grant Accessibility Permission…",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Quit Apps When Last Window Closes",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        if let app = lastFrontApp, let bundleID = app.bundleIdentifier,
           !Self.alwaysExcluded.contains(bundleID) {
            let name = app.localizedName ?? bundleID
            let item = NSMenuItem(title: "Never Quit \(name)",
                                  action: #selector(toggleExcludeFront), keyEquivalent: "")
            item.target = self
            item.state = excluded.contains(bundleID) ? .on : .off
            item.representedObject = bundleID
            menu.addItem(item)
        }

        let excludedItem = NSMenuItem(title: "Excluded Apps", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if excluded.isEmpty {
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for bundleID in excluded.sorted() {
                let item = NSMenuItem(title: displayName(for: bundleID),
                                      action: #selector(removeExclusion(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bundleID
                item.toolTip = "Click to remove from the list"
                sub.addItem(item)
            }
        }
        excludedItem.submenu = sub
        menu.addItem(excludedItem)

        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        let hint = NSMenuItem(title: "Tip: hold ⇧ while clicking ✕ to just close", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CloseQuit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    @objc private func toggleEnabled() { enabled.toggle() }

    @objc private func toggleExcludeFront(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var set = excluded
        if set.contains(bundleID) { set.remove(bundleID) } else { set.insert(bundleID) }
        excluded = set
    }

    @objc private func removeExclusion(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var set = excluded
        set.remove(bundleID)
        excluded = set
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
