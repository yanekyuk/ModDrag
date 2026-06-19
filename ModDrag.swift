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
    /// How close (in points) the cursor must be to a screen edge to arm a snap.
    let snapEdgeThreshold: CGFloat
    /// Vertical extent (from the top/bottom screen edge) of the corner zones that
    /// arm a quarter-tile instead of a half/full tile.
    let snapCornerExtent: CGFloat
    /// Uniform gap (in points) left around snapped windows — both from the screen
    /// edges and between adjacent tiles.
    let snapMargin: CGFloat

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
        updateInterval: 1.0 / 240.0,
        snapEdgeThreshold: 8,
        snapCornerExtent: 120,
        snapMargin: 8
    )
}

// MARK: - Snap Targets
//
// ModDrag moves windows directly via the Accessibility API, so the cursor never
// moves and edge-tiling is implemented in-process rather than relying on the
// WindowServer. A SnapTarget is a tile the window will jump to on release; it
// carries both the Cocoa frame (bottom-left origin) for the on-screen preview
// and the AX frame (top-left origin) used to position and size the window.
struct SnapTarget: Equatable {
    let cocoaFrame: NSRect  // for the NSWindow preview overlay
    let axFrame: CGRect  // for AXPosition / AXSize
}

// MARK: - Snap Preview Style

/// The look of the snap preview overlay. Tunable live from the menu bar and
/// persisted across launches, so the user can pick a vibe without rebuilding.
struct SnapPreviewStyle: Equatable {
    /// How the pane is filled. The glass fills use an NSVisualEffectView with
    /// behind-window blending, so they blur and tint from the desktop wallpaper.
    enum Fill: String, CaseIterable {
        case glassDark  // dark translucent glass (.hudWindow)
        case glassLight  // light translucent glass (.popover)
        case vibrant  // soft wallpaper-tinted glass (.underWindowBackground)
        case accentTint  // accent-colored selection glass (.selection)
        case solidAccent  // flat accent fill, no blur

        var title: String {
            switch self {
            case .glassDark: return "Glass (Dark)"
            case .glassLight: return "Glass (Light)"
            case .vibrant: return "Vibrant"
            case .accentTint: return "Accent Tint"
            case .solidAccent: return "Solid Accent"
            }
        }

        var material: NSVisualEffectView.Material {
            switch self {
            case .glassDark: return .hudWindow
            case .glassLight: return .popover
            case .vibrant: return .underWindowBackground
            case .accentTint: return .selection
            case .solidAccent: return .hudWindow  // unused (solid uses a plain layer)
            }
        }
    }

    var fill: Fill
    var cornerRadius: CGFloat

    static let `default` = SnapPreviewStyle(fill: .glassDark, cornerRadius: 14)
}

/// Loads/saves the snap preview style to UserDefaults.
enum SnapSettings {
    private static let fillKey = "snapPreviewFill"
    private static let radiusKey = "snapPreviewCornerRadius"
    private static let marginKey = "snapMargin"

    static func load() -> SnapPreviewStyle {
        let defaults = UserDefaults.standard
        let fill =
            SnapPreviewStyle.Fill(rawValue: defaults.string(forKey: fillKey) ?? "")
            ?? SnapPreviewStyle.default.fill
        let radius =
            defaults.object(forKey: radiusKey) != nil
            ? CGFloat(defaults.double(forKey: radiusKey))
            : SnapPreviewStyle.default.cornerRadius
        return SnapPreviewStyle(fill: fill, cornerRadius: radius)
    }

    static func save(_ style: SnapPreviewStyle) {
        let defaults = UserDefaults.standard
        defaults.set(style.fill.rawValue, forKey: fillKey)
        defaults.set(Double(style.cornerRadius), forKey: radiusKey)
    }

    static func loadMargin(default fallback: CGFloat) -> CGFloat {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: marginKey) != nil
            ? CGFloat(defaults.double(forKey: marginKey)) : fallback
    }

    static func saveMargin(_ margin: CGFloat) {
        UserDefaults.standard.set(Double(margin), forKey: marginKey)
    }
}

// MARK: - Snap Preview Overlay
//
// A borderless, click-through, non-activating window that shows a styled pane
// over the tile the window will snap to. The glass fills use an
// NSVisualEffectView with behind-window blending, which blurs and samples
// whatever is behind it, so the glass takes on the desktop wallpaper's colors.
final class SnapPreview {
    private let window: NSWindow
    private(set) var style: SnapPreviewStyle

    init(style: SnapPreviewStyle) {
        self.style = style
        window = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        applyStyle(style)
    }

    /// Rebuilds the overlay's content view for `style`. Cheap and only happens on
    /// a menu selection, so swapping the whole content view is fine.
    func applyStyle(_ style: SnapPreviewStyle) {
        self.style = style
        let radius = style.cornerRadius

        if style.fill == .solidAccent {
            let view = NSView(frame: .zero)
            view.wantsLayer = true
            if let layer = view.layer {
                layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
                layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
                layer.borderWidth = 2
                layer.cornerRadius = radius
                layer.masksToBounds = true
            }
            window.contentView = view
            return
        }

        let effect = NSVisualEffectView(frame: .zero)
        effect.material = style.fill.material
        effect.blendingMode = .behindWindow  // blur + tint from the wallpaper behind
        effect.state = .active
        effect.isEmphasized = true
        effect.wantsLayer = true
        if let layer = effect.layer {
            layer.cornerRadius = radius
            layer.masksToBounds = true
            // Subtle rim light so the glass edge reads against any wallpaper.
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
        window.contentView = effect
    }

    /// Shows the preview at `frame` (Cocoa coordinates), without stealing focus.
    func show(_ frame: NSRect) {
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
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
    private let snapEdgeThreshold: CGFloat
    private let snapCornerExtent: CGFloat
    /// Live-adjustable from Settings; persisted via SnapSettings.
    private var snapMargin: CGFloat

    private var state: DraggerState = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Drag state
    private var initialMousePosition: CGPoint = .zero
    private var initialWindowOrigin: CGPoint = .zero
    private var capturedWindow: AXUIElement?
    private var capturedPID: pid_t = 0
    /// Translucent overlay marking the tile the window will snap to on release.
    private let snapPreview = SnapPreview(style: SnapSettings.load())
    /// The tile armed by the current cursor position, committed on drag end.
    private var currentSnap: SnapTarget?
    /// Token for debouncing the sample-flash auto-hide (see flashPreviewSample).
    private var flashGeneration = 0

    // Off-thread AX writes.
    //
    // AX is synchronous cross-process IPC. Calling it from the synchronous
    // event-tap callback can deadlock against the window server (which is waiting
    // for that very callback to return) and freeze ALL input for as long as the
    // target app stays busy. So every window mutation is dispatched to this serial
    // queue (coalesced, latest-wins) and never runs on the tap thread; every AX
    // element we still read on the tap thread gets a short messaging timeout as a
    // hard backstop so it can never block for more than a fraction of a second.
    private static let axTimeout: Float = 0.2
    private let axQueue = DispatchQueue(label: "com.yanek.moddrag.ax", qos: .userInteractive)
    private let axLock = NSLock()
    private var pendingWindow: AXUIElement?
    private var pendingOrigin: CGPoint?
    private var pendingSize: CGSize?
    private var axDraining = false

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
        self.snapEdgeThreshold = configuration.snapEdgeThreshold
        self.snapCornerExtent = configuration.snapCornerExtent
        self.snapMargin = SnapSettings.loadMargin(default: configuration.snapMargin)
    }

    // MARK: - Snap Preview Style (menu-bar settings)

    /// The live snap-preview style. Read by the menu to build its checkmarks.
    func currentPreviewStyle() -> SnapPreviewStyle {
        snapPreview.style
    }

    /// Applies a new preview style, persists it, and flashes a sample so the user
    /// sees the change immediately without having to start a drag.
    func setPreviewStyle(_ style: SnapPreviewStyle) {
        snapPreview.applyStyle(style)
        SnapSettings.save(style)
        flashPreviewSample()
    }

    /// The live tile gap. Read by Settings to build its slider.
    func currentMargin() -> CGFloat {
        snapMargin
    }

    /// Updates the tile gap, persists it, and flashes a sample.
    func setSnapMargin(_ margin: CGFloat) {
        snapMargin = margin
        SnapSettings.saveMargin(margin)
        flashPreviewSample()
    }

    /// Briefly shows the preview over the left half of the main screen so a style
    /// change is visible at a glance. No-op during an actual drag. A generation
    /// token ensures only the latest flash's auto-hide fires, so dragging a
    /// settings slider keeps the sample steady instead of flickering.
    func flashPreviewSample() {
        guard state != .dragging, let vf = NSScreen.main?.visibleFrame else { return }
        let g = snapMargin
        let area = vf.insetBy(dx: g, dy: g)
        let sample = NSRect(
            x: area.minX, y: area.minY,
            width: (area.width - g) / 2, height: area.height)
        snapPreview.show(sample)
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self, self.state != .dragging,
                self.flashGeneration == generation
            else { return }
            self.snapPreview.hide()
        }
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
        // Note: leftMouseDragged is intentionally not tapped — ModDrag drives
        // moves from mouseMoved while a modifier is held, so tapping fewer event
        // types keeps this synchronous (active) tap as light as possible.
        let eventMask =
            (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

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
            // End any in-flight operation (hides the snap preview, commits/aborts
            // cleanly) before re-enabling the tap.
            if state == .dragging || state == .resizing {
                stopCurrentOperation()
            }
            if let tap = eventTap {
                Log.info("⚠️ Event tap disabled, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            if keyCode == emergencyStopKeyCode {
                // Only consume Esc when it actually cancels an in-flight
                // operation. Otherwise pass it through so Esc keeps working
                // system-wide (closing menus, exiting fields, vim, etc.).
                if state == .dragging || state == .resizing {
                    stopCurrentOperation()
                    return nil
                }
                return Unmanaged.passUnretained(event)
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
                    stopDragging(commitSnap: false)
                    startResizing(window: windowRef, initialMouse: location)
                } else {
                    stopDragging(commitSnap: false)
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
        boundAX(systemWide)

        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(location.x), Float(location.y), &element)

        guard result == .success, let uiElement = element else {
            return nil
        }
        boundAX(uiElement)

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
                boundAX(currentElement)
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
        boundAX(window)
        // Get window position and PID
        guard let windowOrigin = getWindowOrigin(window),
            let pid = getWindowPID(window)
        else {
            Log.info("❌ Failed to get window info")
            return
        }

        // Raise/activate the window's app so the move targets the front window.
        activateApp(pid: pid)

        // Store drag state
        capturedWindow = window
        capturedPID = pid
        initialMousePosition = initialMouse
        initialWindowOrigin = windowOrigin
        currentSnap = nil
        state = .dragging

        Log.info("🎯 Dragging window (PID: \(pid))")
    }

    private func updateWindowPosition(currentMouse: CGPoint) {
        guard let window = capturedWindow else {
            stopDragging()
            return
        }

        // Move the window 1:1 with the cursor via the Accessibility API — the
        // cursor itself never moves, so the user's pointer stays predictable.
        let deltaX = currentMouse.x - initialMousePosition.x
        let deltaY = currentMouse.y - initialMousePosition.y
        let newOrigin = CGPoint(
            x: initialWindowOrigin.x + deltaX,
            y: initialWindowOrigin.y + deltaY)
        // Off the tap thread — a synchronous AX move here could deadlock input.
        enqueueWindowWrite(window: window, origin: newOrigin, size: nil)

        updateSnapPreview(cursor: currentMouse)
    }

    /// Re-evaluates which tile (if any) the cursor is hovering and shows/hides the
    /// preview overlay accordingly. Only touches the overlay when the target
    /// actually changes, so it isn't re-shown every mouse move.
    private func updateSnapPreview(cursor: CGPoint) {
        let target = snapTarget(forCursor: cursor)
        if target == currentSnap { return }
        currentSnap = target
        if let target = target {
            snapPreview.show(target.cocoaFrame)
        } else {
            snapPreview.hide()
        }
    }

    /// Maps a cursor position (CG global, top-left origin) to the tile it should
    /// snap to, or nil when it isn't near a snappable edge. Edges give half tiles,
    /// the top gives a full tile, and the corners give quarter tiles — all sized
    /// to the screen's visibleFrame (below the menu bar, beside the Dock).
    private func snapTarget(forCursor cgCursor: CGPoint) -> SnapTarget? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        // CG (top-left) -> Cocoa (bottom-left) global point.
        let cocoaCursor = CGPoint(x: cgCursor.x, y: primaryHeight - cgCursor.y)
        guard
            let screen = NSScreen.screens.first(where: {
                NSMouseInRect(cocoaCursor, $0.frame, false)
            }) ?? NSScreen.main
        else { return nil }

        let frame = screen.frame  // full screen, for edge detection
        let vf = screen.visibleFrame  // tile area, excludes menu bar + Dock
        let edge = snapEdgeThreshold
        let corner = snapCornerExtent

        let atLeft = cocoaCursor.x <= frame.minX + edge
        let atRight = cocoaCursor.x >= frame.maxX - edge
        let atTop = cocoaCursor.y >= frame.maxY - edge  // Cocoa: top is high y
        let nearTop = cocoaCursor.y >= frame.maxY - corner
        let nearBottom = cocoaCursor.y <= frame.minY + corner

        // Inset the usable area by the margin, then split it leaving a margin-sized
        // gap between halves/quarters — so every tile keeps a uniform gap from the
        // screen edges and from its neighbors.
        let g = snapMargin
        let area = vf.insetBy(dx: g, dy: g)
        let halfW = (area.width - g) / 2
        let halfH = (area.height - g) / 2
        let leftX = area.minX
        let rightX = area.maxX - halfW
        let botY = area.minY
        let topY = area.maxY - halfH

        let leftHalf = NSRect(x: leftX, y: area.minY, width: halfW, height: area.height)
        let rightHalf = NSRect(x: rightX, y: area.minY, width: halfW, height: area.height)
        let topLeft = NSRect(x: leftX, y: topY, width: halfW, height: halfH)
        let topRight = NSRect(x: rightX, y: topY, width: halfW, height: halfH)
        let botLeft = NSRect(x: leftX, y: botY, width: halfW, height: halfH)
        let botRight = NSRect(x: rightX, y: botY, width: halfW, height: halfH)

        let cocoaFrame: NSRect?
        if atLeft && nearTop {
            cocoaFrame = topLeft
        } else if atLeft && nearBottom {
            cocoaFrame = botLeft
        } else if atRight && nearTop {
            cocoaFrame = topRight
        } else if atRight && nearBottom {
            cocoaFrame = botRight
        } else if atLeft {
            cocoaFrame = leftHalf
        } else if atRight {
            cocoaFrame = rightHalf
        } else if atTop {
            cocoaFrame = area  // full
        } else {
            cocoaFrame = nil
        }

        guard let cf = cocoaFrame else { return nil }
        return SnapTarget(
            cocoaFrame: cf,
            axFrame: axFrame(fromCocoa: cf, primaryHeight: primaryHeight))
    }

    /// Converts a Cocoa frame (bottom-left origin) to the CG/AX frame (top-left
    /// origin) used by AXPosition/AXSize. The y axis flips about the primary
    /// screen's height; x is unchanged.
    private func axFrame(fromCocoa rect: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// Ends a drag. When `commitSnap` is true and a tile is armed, the window is
    /// snapped to it via AX; otherwise the window just stays where it was dragged.
    /// `commitSnap` is false when the drag is being converted into a resize.
    private func stopDragging(commitSnap: Bool = true) {
        if commitSnap, let window = capturedWindow, let snap = currentSnap {
            enqueueWindowWrite(
                window: window, origin: snap.axFrame.origin, size: snap.axFrame.size)
        }
        snapPreview.hide()
        currentSnap = nil
        capturedWindow = nil
        capturedPID = 0
        initialMousePosition = .zero
        initialWindowOrigin = .zero
        state = .idle
        Log.info("💤 Idle")
    }

    // MARK: - Resize Functions

    private func startResizing(window: AXUIElement, initialMouse: CGPoint) {
        boundAX(window)
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

        // Off the tap thread — a synchronous AX resize here could deadlock input.
        enqueueWindowWrite(window: window, origin: nil, size: newSize)
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

    // MARK: - AX Safety (off-thread writes + bounded timeouts)

    /// Caps how long any message to `element` can block. Set on every element we
    /// read on the event-tap thread so a busy app can never wedge input.
    private func boundAX(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, WindowDragger.axTimeout)
    }

    /// Queues a window move/resize to run off the event-tap thread, coalescing to
    /// the latest requested origin/size so a slow app can't back the queue up.
    /// Never call AX to move a window directly from the tap callback.
    private func enqueueWindowWrite(window: AXUIElement, origin: CGPoint?, size: CGSize?) {
        axLock.lock()
        pendingWindow = window
        if let origin = origin { pendingOrigin = origin }
        if let size = size { pendingSize = size }
        let shouldStart = !axDraining
        if shouldStart { axDraining = true }
        axLock.unlock()
        guard shouldStart else { return }
        axQueue.async { [weak self] in self?.drainWindowWrites() }
    }

    private func drainWindowWrites() {
        while true {
            axLock.lock()
            guard let window = pendingWindow, pendingOrigin != nil || pendingSize != nil else {
                axDraining = false
                pendingWindow = nil
                axLock.unlock()
                return
            }
            let origin = pendingOrigin
            let size = pendingSize
            pendingOrigin = nil
            pendingSize = nil
            axLock.unlock()
            // Size first so a window can shrink before moving into a smaller tile,
            // then position, then size again so stubborn windows settle into it.
            if let size = size { _ = setWindowSize(window: window, size: size) }
            if let origin = origin { _ = setWindowOrigin(window: window, origin: origin) }
            if let size = size { _ = setWindowSize(window: window, size: size) }
        }
    }
}

// MARK: - Settings Window

/// A small programmatic preferences window for tuning the snap preview live.
/// Changes apply to the dragger immediately (and flash a sample), and are
/// persisted by the dragger via SnapSettings.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let dragger: WindowDragger
    private var window: NSWindow?

    private var stylePopUp: NSPopUpButton?
    private var cornerSlider: NSSlider?
    private var cornerValue: NSTextField?
    private var marginSlider: NSSlider?
    private var marginValue: NSTextField?

    init(dragger: WindowDragger) {
        self.dragger = dragger
        super.init()
    }

    /// Builds the window on first use, then brings it (and the app) to the front.
    func show() {
        if window == nil { buildWindow() }
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "ModDrag Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let stylePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        stylePopUp.addItems(withTitles: SnapPreviewStyle.Fill.allCases.map { $0.title })
        stylePopUp.target = self
        stylePopUp.action = #selector(styleChanged)
        self.stylePopUp = stylePopUp

        let cornerSlider = NSSlider(value: 14, minValue: 0, maxValue: 28, target: self,
            action: #selector(cornerChanged))
        self.cornerSlider = cornerSlider
        let cornerValue = makeValueLabel()
        self.cornerValue = cornerValue

        let marginSlider = NSSlider(value: 8, minValue: 0, maxValue: 40, target: self,
            action: #selector(marginChanged))
        self.marginSlider = marginSlider
        let marginValue = makeValueLabel()
        self.marginValue = marginValue

        let grid = NSGridView(views: [
            [makeLabel("Style:"), stylePopUp],
            [makeLabel("Corner radius:"), sliderRow(cornerSlider, cornerValue)],
            [makeLabel("Tile gap:"), sliderRow(marginSlider, marginValue)],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let hint = makeLabel(
            "Changes apply instantly and a sample flashes on your main screen.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            hint.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            hint.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ])
        win.contentView = content
        window = win
    }

    // MARK: Control factories

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        return label
    }

    private func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "0")
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func sliderRow(_ slider: NSSlider, _ value: NSTextField) -> NSView {
        let stack = NSStackView(views: [slider, value])
        stack.orientation = .horizontal
        stack.spacing = 8
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        value.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return stack
    }

    // MARK: Sync + actions

    /// Pulls the dragger's current values into the controls (on open).
    private func syncControls() {
        let style = dragger.currentPreviewStyle()
        let margin = dragger.currentMargin()
        if let index = SnapPreviewStyle.Fill.allCases.firstIndex(of: style.fill) {
            stylePopUp?.selectItem(at: index)
        }
        cornerSlider?.doubleValue = Double(style.cornerRadius)
        cornerValue?.stringValue = "\(Int(style.cornerRadius))"
        marginSlider?.doubleValue = Double(margin)
        marginValue?.stringValue = "\(Int(margin))"
    }

    @objc private func styleChanged() {
        guard let index = stylePopUp?.indexOfSelectedItem,
            SnapPreviewStyle.Fill.allCases.indices.contains(index)
        else { return }
        var style = dragger.currentPreviewStyle()
        style.fill = SnapPreviewStyle.Fill.allCases[index]
        dragger.setPreviewStyle(style)
    }

    @objc private func cornerChanged() {
        guard let slider = cornerSlider else { return }
        let radius = CGFloat(slider.doubleValue.rounded())
        cornerValue?.stringValue = "\(Int(radius))"
        var style = dragger.currentPreviewStyle()
        style.cornerRadius = radius
        dragger.setPreviewStyle(style)
    }

    @objc private func marginChanged() {
        guard let slider = marginSlider else { return }
        let margin = CGFloat(slider.doubleValue.rounded())
        marginValue?.stringValue = "\(Int(margin))"
        dragger.setSnapMargin(margin)
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
    private var settingsController: SettingsWindowController?

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
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(makeQuitItem())

        item.menu = menu
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(dragger: dragger)
        }
        settingsController?.show()
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

        // ModDrag presents its own permission dialog (presentPermissionAlert);
        // we deliberately do NOT fire the macOS "AXTrustedCheckOptionPrompt"
        // system prompt, which would stack a second, redundant dialog on top.

        // Poll so we can relaunch the moment the user grants access.
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
            // A freshly granted accessibility right is not reliably picked up by
            // an already-running event tap, so relaunch cleanly instead of
            // starting the dragger in-place.
            self.relaunchAndQuit()
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

    /// Relaunches ModDrag and terminates the current instance. Used right after
    /// the user grants Accessibility access so the new process starts with the
    /// permission already in effect.
    private func relaunchAndQuit() {
        let task = Process()
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            // Running from ModDrag.app — re-open the bundle as a new instance.
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
        } else {
            // Running as a bare binary — re-exec the executable directly.
            task.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            task.arguments = Array(CommandLine.arguments.dropFirst())
        }

        do {
            try task.run()
        } catch {
            Log.info("⚠️ Failed to relaunch after permission grant: \(error). Starting in-place.")
            startDragger()
            return
        }

        NSApplication.shared.terminate(nil)
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
