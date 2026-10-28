import AppKit
import SwiftUI

@main
struct PenDriverApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--list-tablets") { Diagnostics.listTablets() }
        let model = AppModel(preview: Snapshot.path != nil)
        _model = State(initialValue: model)
        SettingsWindow.shared.model = model
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $model.settings.showMenuBarIcon) {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.settings.enabled ? "pencil.tip" : "pencil.slash")
        }
    }
}

private struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Button("Settings…") { SettingsWindow.shared.show() }
            .keyboardShortcut(",")
        Toggle("Pen Enabled", isOn: $model.settings.enabled)
        Divider()
        Button("Quit Pen Driver") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = Snapshot.path {
            Snapshot.write(to: path)
        } else if !Self.launchedAsLoginItem {
            SettingsWindow.shared.show()
        }
    }

    /// Launching the app again while it runs (Finder, Spotlight) brings up the window.
    /// This is the way back in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    /// Started by macOS at login: stay out of the way.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// The settings window. Pen Driver is a menu bar app; while this window is open it also
/// shows in the Dock and app switcher, like System Settings.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    var model: AppModel!
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.setLiveUpdates(true)
    }

    func makeWindow(pane: Pane = .mapping) -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(model: model, selection: pane))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // An (empty) unified toolbar puts the pane title on the left, as in System Settings.
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.title = pane.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 680))
        if !window.setFrameUsingName("Settings") { window.center() }
        window.setFrameAutosaveName("Settings")
        self.window = window
        return window
    }

    func setPane(_ pane: Pane) {
        window?.title = pane.title
    }

    func windowWillClose(_ notification: Notification) {
        model.setLiveUpdates(false)
        NSApp.setActivationPolicy(.accessory)
    }
}

/// `--snapshot <file.png> [--pane mapping|pen|tablet|general] [--dark]`: renders the settings
/// window with sample data and quits.
enum Snapshot {
    static var path: String? { argument("--snapshot") }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func write(to path: String) {
        let window = SettingsWindow.shared.makeWindow(pane: argument("--pane").flatMap(Pane.init) ?? .mapping)
        window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 760, height: Double(argument("--height") ?? "720") ?? 720))
        if !CommandLine.arguments.contains("--onscreen") { window.setFrameOrigin(NSPoint(x: -4000, y: 0)) }
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let view = window.contentView!.superview!
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

enum Diagnostics {
    /// `--list-tablets`: enumerates supported tablets without opening them, prints, and quits.
    static func listTablets() -> Never {
        let driver = TabletDriver()
        var found: [TabletInfo] = []
        driver.onTabletsChanged = { found = $0 }
        driver.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        print(found.isEmpty ? "No supported tablet found." : found.map {
            String(format: "%@ — %.1f × %.1f mm", $0.name, $0.widthMM, $0.heightMM)
        }.joined(separator: "\n"))
        print("Real-time HID thread: \(Realtime.lastResult == KERN_SUCCESS ? "yes" : "no (\(Realtime.lastResult))")")
        exit(0)
    }
}
