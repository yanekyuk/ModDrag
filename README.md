# ModDrag

ModDrag is a lightweight Swift CLI that lets you move and resize macOS windows by holding configurable shortcuts. It relies only on public accessibility APIs and does not require any additional daemons or helpers.

## Features

-   A menu bar (system tray) icon that shows ModDrag is running and offers a one-click **Quit ModDrag**
-   Configurable drag and resize shortcuts that can be modifier-only or a key plus modifiers
-   Smooth window movement with 240 Hz rate limiting for responsive tracking without unnecessary CPU load
-   Seamless switching between dragging and resizing while keeping the same window captured
-   Safety controls: press the `Esc` key to cancel the current action or `Ctrl+C` to terminate the app
-   Built-in guards that skip fullscreen or minimised windows and enforce a minimum window size

## Build

### App bundle (recommended)

Double-clicking a bare Unix executable in Finder forces macOS to run it inside
Terminal. To get a true no-terminal launch, build the `.app` bundle:

```bash
./build-app.sh
```

This compiles `ModDrag.swift`, wraps the binary in `ModDrag.app` (with `LSUIElement`
set so it runs as a menu-bar accessory), and ad-hoc code-signs it. Launch it with:

```bash
open ModDrag.app
```

or by double-clicking `ModDrag.app` in Finder. It appears in the menu bar with no
Dock icon and no terminal window. Because the bundle has its own identity, macOS
treats it as a distinct app for Accessibility — grant **ModDrag** access on first
launch (see below).

### Bare binary

For terminal use (e.g. `--log` debugging) you can build just the executable:

```bash
swiftc -O ModDrag.swift -o mod-drag
```

No `-parse-as-library` flag is needed: the entry point is plain top-level code
(`runModDrag()` at the bottom of `ModDrag.swift`) rather than `@main`. Compiling a
single file with `swiftc` always uses script mode, which rejects `@main`
("cannot be used in a module that contains top-level code") but accepts top-level
statements.

If the compiler reports that it cannot write the Swift module cache, re-run the command with sufficient permissions (the tool needs to write to `~/Library/Developer/Xcode/DerivedData` or `~/.cache/clang/ModuleCache`).

## Usage

1. **Launch ModDrag**

    ```bash
    open ModDrag.app   # GUI launch, no terminal
    # or, for terminal/debugging use:
    ./mod-drag
    ```

2. **Grant accessibility access** (first run only and if needed)

    On first launch ModDrag asks macOS for Accessibility access and shows a dialog
    with an **Open Accessibility Settings** button — no terminal required.

    - Click **Open Accessibility Settings** (in the dialog or the menu-bar menu) to
      jump straight to **System Settings → Privacy & Security → Accessibility**
    - Enable **mod-drag** in the list
    - ModDrag detects the grant and starts automatically within about a second —
      no relaunch needed

3. **Interact**

    - Hold the drag shortcut and move the mouse to relocate the window under the cursor
    - Hold the resize shortcut and move the mouse to resize the captured window
    - Press `Esc` to abandon the current operation

Console logs show the current state (`Idle`, `Armed`, `Dragging`, `Resize Armed`, `Resizing`) so you can confirm what the tool is doing at any moment.

## Menu Bar Icon

While ModDrag is running, a window icon appears in the macOS menu bar. Its presence is the quickest way to confirm the tool is active. Click it to open a menu with:

-   **ModDrag — Running** — a status line confirming the tool is live
-   **Quit ModDrag** (`⌘Q`) — cleanly stops the tool

If accessibility access is missing, the icon shows a warning glyph and the menu
adds an **Open Accessibility Settings…** entry; both disappear once access is
granted and the tool starts.

ModDrag runs as an accessory app, so it stays out of the Dock and the app switcher.
It no longer needs a terminal — though you can still launch it from one and quit
with `Ctrl+C`, and `--log` prints state transitions for debugging.

## Default Shortcuts

The defaults live in `WindowDraggerConfiguration.default` inside `ModDrag.swift`:

```swift
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
```

-   `keyCode: 0` means “modifier-only” behaviour; the shortcut fires as soon as the listed modifiers are held.
-   Use `keyCode` with a non-zero value (for example `49` for Space or `96` for F5) to require an explicit key press.
-   `emergencyStopKeyCode` is the macOS key code for the emergency stop key (`53` is `Esc`).
-   The `minimumWindowSize` guard prevents collapsing a window below 100×100 points.

### Finding key codes

macOS key codes differ from printable characters. Useful references:

-   49 – Space
-   53 – Esc
-   96 – F5
-   97 – F6
-   98 – F7
-   99 – F8

You can add new codes to the `keyName(for:)` helper if you use additional keys and want them to appear nicely in the console output.

## Customising Behaviour

-   Adjust the `dragHotKey` and `resizeHotKey` values to tailor the shortcuts to your workflow.
-   Change `minimumWindowSize` if you prefer a different lower bound when resizing.
-   Modify `updateInterval` to raise or lower the refresh rate. Lower values increase CPU usage but make movement more responsive.

Rebuild after any changes:

```bash
./build-app.sh                                   # app bundle
swiftc -O ModDrag.swift -o mod-drag                  # bare binary
```

## Troubleshooting

-   **Nothing happens after launch** – check the menu bar. If the icon shows a warning, accessibility access is missing; use **Open Accessibility Settings…** from its menu and enable `mod-drag`. ModDrag starts automatically once access is granted.
-   **A window does not move** – some system or sandboxed apps disallow programmatic movement; the tool skips those windows.
-   **Logs show “Failed to move/resize window”** – the app probably rejected the accessibility command. Releasing and re-engaging the shortcut usually resets the state.
