import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum Log {
    private static var isEnabled = false

    static func configure(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    static func info(_ message: String) {
        guard isEnabled else { return }
        emit(message)
    }

    static func always(_ message: String) {
        emit(message)
    }

    private static func emit(_ message: String) {
        if message.hasSuffix("\n") {
            fputs(message, stderr)
        } else {
            fputs(message + "\n", stderr)
        }
    }
}

// MARK: - Accessibility Permission

/// Thin wrapper over the Accessibility trust APIs. Keeps the permission
/// vocabulary (check / prompt / open-settings) in one place so the AppDelegate
/// can drive a fully graphical flow without depending on terminal output.
enum AccessibilityPermission {
    /// Whether this process is currently trusted for the Accessibility API.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the macOS "would like to control this computer" system prompt.
    /// Returns the current trust state. Safe to call repeatedly; macOS shows the
    /// prompt at most once per app until the user responds.
    @discardableResult
    static func prompt() -> Bool {
        // Literal key value of kAXTrustedCheckOptionPrompt ("AXTrustedCheckOptionPrompt").
        // Using the literal avoids the Unmanaged<CFString> vs CFString bridging
        // differences of the imported constant across SDK versions.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly on Privacy & Security → Accessibility.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Configuration

struct HotKeyConfiguration {
    let keyCode: UInt16
    let modifiers: CGEventFlags

    var usesKeyCode: Bool { keyCode != 0 }

    func matchesKeyEvent(_ event: CGEvent) -> Bool {
        guard usesKeyCode else { return false }
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return eventKeyCode == keyCode && modifiers.isSubset(of: event.flags)
    }

    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        modifiers.isSubset(of: flags)
    }
}

struct WindowDraggerConfiguration {
    let dragHotKey: HotKeyConfiguration
    let resizeHotKey: HotKeyConfiguration
    let emergencyStopKeyCode: UInt16
    let minimumWindowSize: CGSize
    let updateInterval: CFTimeInterval

    static let `default` = WindowDraggerConfiguration(
        dragHotKey: HotKeyConfiguration(
            keyCode: 0,
            modifiers: [.maskControl]
        ),
        resizeHotKey: HotKeyConfiguration(
            keyCode: 0,
            modifiers: [.maskControl, .maskAlternate]
        ),
        emergencyStopKeyCode: 53,
        minimumWindowSize: CGSize(width: 100, height: 100),
        updateInterval: 1.0 / 240.0
    )
}

// MARK: - State Management
enum DraggerState {
    case idle
    case armed
    case dragging
    case resizeArmed
    case resizing
}

// MARK: - Main Window Dragger
class WindowDragger {
    private let configuration: WindowDraggerConfiguration
    private let dragHotKey: HotKeyConfiguration
    private let resizeHotKey: HotKeyConfiguration
    private let emergencyStopKeyCode: UInt16
    private let minimumWindowSize: CGSize
    private let updateInterval: CFTimeInterval

    private var state: DraggerState = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Drag state
    private var initialMousePosition: CGPoint = .zero
    private var initialWindowOrigin: CGPoint = .zero
    private var capturedWindow: AXUIElement?
    private var capturedPID: pid_t = 0

    // Resize state
    private var initialWindowSize: CGSize = .zero

    // Rate limiting
    private var lastUpdateTime: CFTimeInterval = 0

    init(configuration: WindowDraggerConfiguration = .default) {
        self.configuration = configuration
        self.dragHotKey = configuration.dragHotKey
        self.resizeHotKey = configuration.resizeHotKey
        self.emergencyStopKeyCode = configuration.emergencyStopKeyCode
        self.minimumWindowSize = configuration.minimumWindowSize
        self.updateInterval = configuration.updateInterval
    }

    /// Performs permission checks and installs the event tap on the current
    /// run loop. Returns `false` if the dragger could not start. The caller is
    /// responsible for running the run loop (e.g. via `NSApplication.run()`).
    @discardableResult
    func start() -> Bool {
        // Check accessibility permissions
        guard checkAccessibilityPermissions() else {
            return false
        }

        // Create event tap
        setupEventTap()

        // Announce startup
        let triggerDescription = hotKeyDescription(for: dragHotKey, action: "Move windows")
        let resizeDescription = hotKeyDescription(for: resizeHotKey, action: "Resize windows")
        Log.always("Window Dragger started.")
        Log.always(triggerDescription)
        Log.always(resizeDescription)
        Log.always(
            "Press \(emergencyStopDescription()) to stop the current operation, Ctrl+C to quit.")

        return true
    }

    private func checkAccessibilityPermissions() -> Bool {
        let trusted = AccessibilityPermission.isTrusted
        if !trusted {
            Log.info("❌ Accessibility permission required (handled by the menu-bar UI).")
        }
        return trusted
    }

    private func hotKeyDescription(for hotKey: HotKeyConfiguration, action: String) -> String {
        let modifierNames = modifierDescription(for: hotKey.modifiers)

        if hotKey.usesKeyCode {
            let keyName = keyName(for: hotKey.keyCode)
            if modifierNames.isEmpty {
                return "\(action): Press \(keyName) and drag the mouse."
            } else {
                return "\(action): Press \(modifierNames)+\(keyName) and drag the mouse."
            }
        }

        if !modifierNames.isEmpty {
            return "\(action): Press \(modifierNames) and drag the mouse."
        }

        return "\(action): Drag the mouse."
    }

    private func emergencyStopDescription() -> String {
        keyName(for: emergencyStopKeyCode)
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 53: return "Esc"
        case 48: return "Tab"
        case 96: return "F20"
        case 105: return "F13"
        case 106: return "F14"
        case 107: return "F15"
        case 109: return "F16"
        case 103: return "F17"
        case 111: return "F18"
        case 113: return "F19"
        default: return "Key(\(keyCode))"
        }
    }

    private func modifierDescription(for modifiers: CGEventFlags) -> String {
        var parts: [String] = []

        if modifiers.contains(.maskCommand) {
            parts.append("Cmd")
        }
        if modifiers.contains(.maskControl) {
            parts.append("Ctrl")
        }
        if modifiers.contains(.maskAlternate) {
            parts.append("Opt")
        }
        if modifiers.contains(.maskShift) {
            parts.append("Shift")
        }

        return parts.joined(separator: "+")
    }

    private func setupEventTap() {
        let eventMask =
            (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 0)!,  // kCGHIDEventTap
            place: CGEventTapPlacement(rawValue: 0)!,  // kCGHeadInsertEventTap
            options: CGEventTapOptions(rawValue: 0)!,  // kCGEventTapOptionDefault
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let dragger = Unmanaged<WindowDragger>.fromOpaque(refcon!).takeUnretainedValue()
                return dragger.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            Log.always("❌ Failed to create event tap")
            exit(1)
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent)
        -> Unmanaged<CGEvent>?
    {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                Log.info("⚠️ Event tap disabled, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            if keyCode == emergencyStopKeyCode {
                if state == .dragging || state == .resizing {
                    stopCurrentOperation()
                }
                return nil
            }

            if dragHotKey.matchesKeyEvent(event) {
                handleTriggerKeyPressed()
                return nil
            }

            if resizeHotKey.matchesKeyEvent(event) {
                handleResizeKeyPressed()
                return nil
            }
        }

        if type == .flagsChanged && (!dragHotKey.usesKeyCode || !resizeHotKey.usesKeyCode) {
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved || type == .leftMouseDragged {
            handleMouseMoved(event: event)
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleTriggerKeyPressed() {
        switch state {
        case .idle:
            state = .armed
            Log.info("🔧 Armed via trigger key")

        case .armed, .dragging:
            stopDragging()

        case .resizeArmed, .resizing:
            stopResizing()
        }
    }

    private func handleResizeKeyPressed() {
        switch state {
        case .idle:
            state = .resizeArmed
            Log.info("📏 Resize armed via trigger key")

        case .resizeArmed, .resizing:
            stopResizing()

        case .armed, .dragging:
            stopDragging()
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let resizeShortcutActive = !resizeHotKey.usesKeyCode && resizeModifiersActive(flags: flags)
        let dragShortcutActive = !dragHotKey.usesKeyCode && dragModifiersActive(flags: flags)
        let dragOnlyActive = dragShortcutActive && !resizeShortcutActive

        if resizeShortcutActive {
            switch state {
            case .idle, .armed:
                state = .resizeArmed
                Log.info("📏 Resize armed - move mouse over a window")
            case .dragging:
                // Let mouse movement handler take care of switching to resize
                break
            case .resizeArmed, .resizing:
                break
            }
        } else if dragOnlyActive {
            switch state {
            case .idle, .resizeArmed:
                state = .armed
                Log.info("🔧 Armed - move mouse over a window")
            case .resizing:
                stopResizing()
                state = .armed
                Log.info("🔧 Armed - move mouse over a window")
            case .armed, .dragging:
                break
            }
        } else {
            // No modifiers are active anymore - stop any ongoing work
            switch state {
            case .armed, .dragging:
                stopDragging()
            case .resizeArmed, .resizing:
                stopResizing()
            case .idle:
                break
            }
        }
    }

    private func handleMouseMoved(event: CGEvent) {
        let flags = event.flags
        let resizeStateActive = state == .resizeArmed || state == .resizing
        let dragStateActive = state == .armed || state == .dragging

        let resizeActive =
            resizeHotKey.usesKeyCode
            ? (resizeStateActive && resizeModifiersActive(flags: flags))
            : resizeModifiersActive(flags: flags)

        let dragActive =
            dragHotKey.usesKeyCode
            ? (dragStateActive && dragModifiersActive(flags: flags))
            : dragModifiersActive(flags: flags)
        let dragOnlyActive = dragActive && !resizeActive

        // Rate limiting
        let currentTime = CFAbsoluteTimeGetCurrent()
        if currentTime - lastUpdateTime < updateInterval {
            return
        }
        lastUpdateTime = currentTime

        // Dynamic switch with priority for dragging
        if dragOnlyActive && (state == .resizing || state == .resizeArmed) {
            // Switch from resizing to dragging
            stopResizing()
            if let window = hitTestWindow(at: event.location) {
                startDragging(window: window, initialMouse: event.location)
            } else {
                state = .armed
                Log.info("🔧 Armed - move mouse over a window")
            }
            return
        }

        switch state {
        case .armed:
            if resizeActive {
                state = .resizeArmed
                Log.info("📏 Resize armed - move mouse over a window")
            } else if dragOnlyActive {
                if let window = hitTestWindow(at: event.location) {
                    startDragging(window: window, initialMouse: event.location)
                }
            } else {
                state = .idle
                Log.info("💤 Idle")
            }

        case .dragging:
            if resizeActive {
                if let window = capturedWindow {
                    let windowRef = window
                    let location = event.location
                    stopDragging()
                    startResizing(window: windowRef, initialMouse: location)
                } else {
                    stopDragging()
                }
            } else if dragOnlyActive && capturedWindow != nil {
                updateWindowPosition(currentMouse: event.location)
            } else {
                stopDragging()
            }

        case .resizeArmed:
            if resizeActive {
                if let window = hitTestWindow(at: event.location) {
                    startResizing(window: window, initialMouse: event.location)
                }
            } else if dragOnlyActive {
                state = .armed
                Log.info("🔧 Armed - move mouse over a window")
            } else {
                state = .idle
                Log.info("💤 Idle")
            }

        case .resizing:
            if resizeActive && capturedWindow != nil {
                updateWindowSize(currentMouse: event.location)
            } else {
                stopResizing()
            }

        case .idle:
            break
        }
    }

    private func dragModifiersActive(flags: CGEventFlags) -> Bool {
        return dragHotKey.matchesModifiers(flags)
    }

    private func resizeModifiersActive(flags: CGEventFlags) -> Bool {
        return resizeHotKey.matchesModifiers(flags)
    }

    private func hitTestWindow(at location: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(location.x), Float(location.y), &element)

        guard result == .success, let uiElement = element else {
            return nil
        }

        // Walk up to find window
        var currentElement = uiElement

        while true {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &role)

            if let roleString = role as? String, roleString == kAXWindowRole {
                // Check if window is movable
                if isWindowMovable(currentElement) {
                    return currentElement
                }
                break
            }

            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                currentElement, kAXParentAttribute as CFString, &parent) == .success,
                let parentElement = parent
            {
                currentElement = parentElement as! AXUIElement
            } else {
                break
            }
        }

        return nil
    }

    private func isWindowMovable(_ window: AXUIElement) -> Bool {
        // Check if window has position attribute (movable)
        var position: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &position)

        guard result == .success else {
            return false
        }

        // Check if window is not minimized
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            == .success,
            let isMinimized = minimized as? Bool, isMinimized
        {
            return false
        }

        // Note: kAXFullscreenAttribute may not be available in all macOS versions
        // Skip fullscreen check for compatibility

        return true
    }

    private func startDragging(window: AXUIElement, initialMouse: CGPoint) {
        // Get window position and PID
        guard let windowOrigin = getWindowOrigin(window),
            let pid = getWindowPID(window)
        else {
            Log.info("❌ Failed to get window info")
            return
        }

        // Activate the application
        activateApp(pid: pid)

        // Store drag state
        capturedWindow = window
        capturedPID = pid
        initialMousePosition = initialMouse
        initialWindowOrigin = windowOrigin
        state = .dragging

        Log.info("🎯 Dragging window (PID: \(pid))")
    }

    private func updateWindowPosition(currentMouse: CGPoint) {
        guard let window = capturedWindow else {
            stopDragging()
            return
        }

        // Calculate delta and new position
        let deltaX = currentMouse.x - initialMousePosition.x
        let deltaY = currentMouse.y - initialMousePosition.y

        let newOrigin = CGPoint(
            x: initialWindowOrigin.x + deltaX,
            y: initialWindowOrigin.y + deltaY
        )

        // Update window position
        if !setWindowOrigin(window: window, origin: newOrigin) {
            Log.info("⚠️ Failed to move window, stopping drag")
            stopDragging()
        }
    }

    private func stopDragging() {
        capturedWindow = nil
        capturedPID = 0
        initialMousePosition = .zero
        initialWindowOrigin = .zero
        state = .idle
        Log.info("💤 Idle")
    }

    // MARK: - Resize Functions

    private func startResizing(window: AXUIElement, initialMouse: CGPoint) {
        // Get window size and PID
        guard let windowSize = getWindowSize(window),
            let pid = getWindowPID(window)
        else {
            Log.info("❌ Failed to get window info for resize")
            return
        }

        // Activate the application
        activateApp(pid: pid)

        // Store resize state
        capturedWindow = window
        capturedPID = pid
        initialMousePosition = initialMouse
        initialWindowSize = windowSize
        state = .resizing

        Log.info("📏 Resizing window (PID: \(pid))")
    }

    private func updateWindowSize(currentMouse: CGPoint) {
        guard let window = capturedWindow else {
            stopResizing()
            return
        }

        // Calculate delta and new size
        let deltaX = currentMouse.x - initialMousePosition.x
        let deltaY = currentMouse.y - initialMousePosition.y

        let newSize = CGSize(
            width: max(minimumWindowSize.width, initialWindowSize.width + deltaX),
            height: max(minimumWindowSize.height, initialWindowSize.height + deltaY)
        )

        // Update window size
        if !setWindowSize(window: window, size: newSize) {
            Log.info("⚠️ Failed to resize window, stopping resize")
            stopResizing()
        }
    }

    private func stopResizing() {
        capturedWindow = nil
        capturedPID = 0
        initialMousePosition = .zero
        initialWindowSize = .zero
        state = .idle
        Log.info("💤 Idle")
    }

    private func stopCurrentOperation() {
        switch state {
        case .dragging:
            stopDragging()
        case .resizing:
            stopResizing()
        default:
            state = .idle
            Log.info("💤 Idle")
        }
    }

    // MARK: - Helper Functions

    private func getWindowOrigin(_ window: AXUIElement) -> CGPoint? {
        var position: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
                == .success,
            let pointValue = position
        else {
            return nil
        }

        var point = CGPoint.zero
        AXValueGetValue(pointValue as! AXValue, AXValueType.cgPoint, &point)
        return point
    }

    private func getWindowPID(_ window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(window, &pid)
        return result == .success ? pid : nil
    }

    private func activateApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }

        app.activate(options: [])
    }

    private func setWindowOrigin(window: AXUIElement, origin: CGPoint) -> Bool {
        var point = origin
        guard let positionValue = AXValueCreate(AXValueType.cgPoint, &point) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue)
        return result == .success
    }

    private func getWindowSize(_ window: AXUIElement) -> CGSize? {
        var size: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
            let sizeValue = size
        else {
            return nil
        }

        var cgSize = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, AXValueType.cgSize, &cgSize)
        return cgSize
    }

    private func setWindowSize(window: AXUIElement, size: CGSize) -> Bool {
        var cgSize = size
        guard let sizeValue = AXValueCreate(AXValueType.cgSize, &cgSize) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return result == .success
    }
}

// MARK: - Status Bar (System Tray)

/// Owns the menu bar status item and runs the dragger inside the AppKit run
/// loop. The presence of the icon in the menu bar signals that ModDrag is
/// running; the menu offers a quick way to quit.
class AppDelegate: NSObject, NSApplicationDelegate {
    private let dragger: WindowDragger
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var draggerStarted = false

    init(dragger: WindowDragger) {
        self.dragger = dragger
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        if AccessibilityPermission.isTrusted {
            startDragger()
        } else {
            enterPermissionNeededState()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        applyRunningAppearance()
    }

    /// Loads the bundled monochrome menu-bar template (TrayIcon.pdf), falling
    /// back to the `macwindow` SF Symbol when running as a bare binary (no bundle).
    private func runningTrayImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "TrayIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url)
        {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let symbol = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "ModDrag")
        symbol?.isTemplate = true
        return symbol
    }

    /// Normal running look: window glyph + a minimal running menu.
    private func applyRunningAppearance() {
        guard let item = statusItem else { return }

        if let button = item.button {
            if let image = runningTrayImage() {
                button.image = image
                button.title = ""
            } else {
                button.image = nil
                button.title = "⬚"
            }
            button.toolTip = "ModDrag — running"
        }

        let menu = NSMenu()

        let statusLine = NSMenuItem(title: "ModDrag — Running", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())
        menu.addItem(makeQuitItem())

        item.menu = menu
    }

    /// Permission-missing look: warning glyph + a menu that links to Settings.
    private func applyPermissionNeededAppearance() {
        guard let item = statusItem else { return }

        if let button = item.button {
            if let image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "ModDrag — accessibility access needed")
            {
                image.isTemplate = true
                button.image = image
                button.title = ""
            } else {
                button.image = nil
                button.title = "⚠️"
            }
            button.toolTip = "ModDrag — accessibility access needed"
        }

        let menu = NSMenu()

        let statusLine = NSMenuItem(
            title: "ModDrag — Accessibility access needed", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(makeQuitItem())

        item.menu = menu
    }

    private func makeQuitItem() -> NSMenuItem {
        let quitItem = NSMenuItem(
            title: "Quit ModDrag",
            action: #selector(quit),
            keyEquivalent: "q")
        quitItem.target = self
        return quitItem
    }

    // MARK: - Dragger lifecycle

    /// Installs the event tap and swaps to the running appearance. Idempotent —
    /// the polling timer may fire more than once before it is invalidated.
    private func startDragger() {
        guard !draggerStarted else { return }

        guard dragger.start() else {
            // Trusted check passed but the tap could not be installed; keep the
            // menu available rather than dying silently.
            statusItem?.button?.toolTip = "ModDrag — failed to start"
            return
        }

        draggerStarted = true
        applyRunningAppearance()
    }

    // MARK: - Permission flow

    private func enterPermissionNeededState() {
        applyPermissionNeededAppearance()

        // Fire the macOS system prompt (D1).
        AccessibilityPermission.prompt()

        // Poll so we can auto-start the moment the user grants access (D2).
        startPollingForPermission()

        // Explain the situation with a direct path to the right Settings pane.
        presentPermissionAlert()
    }

    private func startPollingForPermission() {
        permissionTimer?.invalidate()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard AccessibilityPermission.isTrusted else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            // If the permission alert is still on screen, dismiss its modal loop
            // first so its now-stale "Quit" button can't terminate the running app.
            if NSApp.modalWindow != nil {
                NSApp.abortModal()
            }
            self.startDragger()
        }
        // .common so the timer keeps firing while the NSAlert modal loop runs.
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "ModDrag needs Accessibility access"
        alert.informativeText =
            "To move and resize windows, enable ModDrag under System Settings → "
            + "Privacy & Security → Accessibility. ModDrag starts automatically once access is granted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AccessibilityPermission.openSettings()
        case .alertSecondButtonReturn:
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main
//
// Entry point as top-level code rather than `@main`. Compiling a single source
// file with `swiftc` always uses script (top-level) mode, where `@main` is
// rejected ("cannot be used in a module that contains top-level code"). Plain
// top-level statements compile cleanly without needing `-parse-as-library`.
func runModDrag() {
    Log.configure(isEnabled: CommandLine.arguments.contains("--log"))

    let dragger = WindowDragger()

    // Handle Ctrl+C (still works when launched from a terminal).
    signal(SIGINT) { _ in
        Log.info("\n👋 Goodbye!")
        exit(0)
    }

    let app = NSApplication.shared
    // Accessory app: live in the menu bar, no Dock icon, no main window.
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate(dragger: dragger)
    app.delegate = delegate
    app.run()
}

runModDrag()
