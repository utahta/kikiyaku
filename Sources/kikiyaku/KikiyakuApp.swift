import AppKit
import SwiftUI

@main
struct KikiyakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            // Route the app menu's "Settings…" (⌘,) to the custom settings
            // window. The SwiftUI Settings scene's own window lacks the fixed
            // sizing that keeps macOS 26 out of a constraint-update loop, and
            // two competing settings windows (this and the status-menu one)
            // must not both exist.
            CommandGroup(replacing: .appSettings) {
                Button(L("menu.settings")) {
                    AppDelegate.requestShowSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var panel: NSPanel?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular activation policy (Dock icon + Cmd+Tab switcher), so the
        // hidden panel can be brought back from the keyboard. The menu bar
        // status item remains the primary control surface.
        makeStatusItem()
        Self.makePanel()
        Self.showPanel()

        // Cmd+W hides the panel. The panel deliberately never becomes the key
        // window (it must not steal focus from the meeting app), so the
        // standard performClose route has nothing to act on; intercept the key
        // event while the app is active instead. When another window (the
        // settings window) is key, keep the standard close behavior.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Compare only the shortcut-relevant modifiers: state flags such as
            // Caps Lock are also present in modifierFlags and would break an
            // exact-equality check against .command.
            guard event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
                  event.charactersIgnoringModifiers == "w" else { return event }
            if let key = NSApp.keyWindow, key != Self.panel {
                key.performClose(nil)
            } else {
                Self.panel?.orderOut(nil)
            }
            return nil
        }
    }

    /// Dock icon click / reopen: bring the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showPanel()
        return false
    }

    /// Any activation (Cmd+Tab included): the panel is the app's face, so
    /// re-show it when the user switches to kikiyaku.
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.showPanel()
        // hidesOnDeactivate re-shows an open settings window on activation, but
        // the panel front-ordering above would then cover it (both windows are
        // .floating, and the last one ordered wins). Keep the settings window —
        // the key window — on top while it is open.
        if let settings = Self.settingsWindow, settings.isVisible {
            settings.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Status item / menu

    /// NSStatusItem instead of SwiftUI's MenuBarExtra: we want the hook at the
    /// moment the menu opens (menuWillOpen) available for future use.
    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "captions.bubble",
            accessibilityDescription: "Kikiyaku"
        )

        let show = NSMenuItem(title: L("menu.showPanel"), action: #selector(showPanelAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let folder = NSMenuItem(title: L("menu.openFolder"), action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func showPanelAction() {
        Self.showPanel()
    }

    @objc private func openFolder() {
        let directory = TranscriptStore.directory
        // Create the folder first in case it does not exist yet (right after first
        // launch, for example) — otherwise open silently does nothing.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func openSettings() {
        Self.requestShowSettings()
    }

    // There is no official API to open a SwiftUI Settings scene from AppKit, and
    // the private selector (showSettingsWindow:) did not work in this environment,
    // so the settings window is managed manually.
    private static var settingsWindow: NSWindow?
    private static var settingsHosting: NSHostingController<SettingsView>?

    /// The only public entry point for opening the settings window. Every
    /// caller is a menu item (status menu, app menu ⌘,), and menu actions run
    /// inside the menu-dismissal display cycle — creating the window right
    /// there makes AppKit throw over "constraint updates during a display
    /// cycle" (macOS 26). Always defer by one runloop turn.
    static func requestShowSettings() {
        DispatchQueue.main.async {
            showSettings()
        }
    }

    private static func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        // Do not let SwiftUI's intrinsic size drive the window size, and cut the
        // safe-area coupling. With both active, the mutual recomputation
        // (window resize → safe-area recalculation → view invalidation → resize …)
        // never converges and macOS 26 crashes with "more Update Constraints in
        // Window passes than there are views".
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("settingsWindow.title")
        // The panel lives at .floating level, so a normal-level settings window
        // would always sit behind it. Match the level; ordering front on show
        // then puts settings above the panel. Unlike the panel, hide when the
        // app deactivates — a floating window would otherwise stay on top of
        // the meeting app too (it reappears on the next activation).
        window.level = .floating
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting.view
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsHosting = hosting
        settingsWindow = window
    }

    @objc private func quit() {
        // Stopping, saving, and the unsaved-data confirmation are centralized in
        // applicationShouldTerminate, so quitting from the menu just rides the
        // standard termination path.
        NSApp.terminate(nil)
    }

    /// Every termination path (menu, ⌘Q from the settings window, logout, external
    /// termination requests) goes through here. If running, stop and save first;
    /// if unsaved data remains after a failed save, ask the user whether to
    /// discard it before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !AppState.shared.isRunning && !Engine.shared.hasUnsavedTranscript {
            return .terminateNow
        }
        Task { @MainActor in
            // When already stopped with unsaved data, stop() retries just the save.
            await Engine.shared.stop()
            var shouldTerminate = true
            if Engine.shared.hasUnsavedTranscript {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("alert.unsaved.title")
                alert.informativeText = L("alert.unsaved.message")
                alert.addButton(withTitle: L("alert.unsaved.cancel"))
                alert.addButton(withTitle: L("alert.unsaved.discard"))
                shouldTerminate = alert.runModal() != .alertFirstButtonReturn
            }
            if !shouldTerminate {
                // Quit cancelled: kill the helper waiting to relaunch, if any.
                Self.relaunchHelper?.terminate()
                Self.relaunchHelper = nil
            }
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    // MARK: - Panel

    static func makePanel() {
        guard panel == nil else { return }
        // .nonactivatingPanel: scrolling and other interactions never steal focus
        // from the meeting app.
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Kikiyaku"
        // No visible window chrome: the title bar would sit over the meeting
        // video. The title and traffic-light buttons are hidden (content uses
        // the full frame) and the panel moves by dragging its background.
        // PanelView un-hides the native close button while the pointer is over
        // the panel. .titled/.closable stay in the style mask for resize edges
        // and the frame autosave.
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(button)?.isHidden = true
        }
        p.level = .floating
        // Stay visible above a full-screen meeting window as well.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.contentView = FirstMouseHostingView(rootView: PanelView(state: AppState.shared))
        p.setFrameAutosaveName("kikiyaku.panel")
        // The SwiftUI side owns the translucency: per-row plates carry the
        // configured opacity while the window itself stays fully transparent,
        // so background video shows through everywhere except behind text.
        p.isOpaque = false
        p.backgroundColor = .clear
        p.delegate = panelDelegate
        panel = p
    }

    // NSWindow.delegate is a weak reference, so the AppDelegate keeps it alive.
    private static let panelDelegate = PanelDelegate()

    static func showPanel() {
        makePanel()
        panel?.orderFrontRegardless()
    }

    /// Helper process waiting to relaunch the app. Killed explicitly when the quit
    /// confirmation dialog is cancelled (left alive, it would suddenly relaunch the
    /// app the moment the user quits manually hours later).
    private static var relaunchHelper: Process?

    /// Relaunches the app (to apply a display-language change). terminate goes
    /// through the normal termination path (applicationShouldTerminate), so even a
    /// running session is stopped and saved before the relaunch. The child sh
    /// outlives its parent and reopens the app with open.
    ///
    /// The helper waits (with no time limit) for the current process to fully exit
    /// before calling open. Even if termination drags on due to stopping/saving or
    /// draining the translation queue, the wait is never cut short into "relaunched
    /// but the app stayed closed". Cleanup on cancel is handled by
    /// applicationShouldTerminate killing relaunchHelper.
    /// The pid and path are passed as positional arguments ($1 / $2) rather than
    /// embedded in the shell string (so paths containing $ or quotes are never
    /// interpreted).
    static func relaunch() {
        // Pressing the button again while terminateLater is stopping/saving would
        // leave multiple waiting helpers, of which quit-cancel can only kill the
        // last (the leftovers would suddenly relaunch the app on a later manual
        // quit). Cap the helpers at one.
        guard relaunchHelper == nil else { return }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        exec /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "kikiyaku-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath,
        ]
        try? process.run()
        relaunchHelper = process
        NSApp.terminate(nil)
    }

}

/// Hosting view that accepts the first mouse click. The panel never becomes
/// key (nonactivating, so it cannot steal focus from the meeting app), which
/// makes every click an "initial click on an inactive window" — SwiftUI
/// controls handle that, but plain tap gestures (the per-row source-text
/// toggle) would be swallowed by it and never fire.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The close button hides the window instead of destroying it.
/// Re-showing is explicit via the "Show Panel" menu item (auto-reshow on icon
/// click was tried and dropped — it did not match the desired experience).
@MainActor
private final class PanelDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
