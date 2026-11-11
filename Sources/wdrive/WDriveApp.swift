import AppKit
import SwiftUI

@main
struct WDriveApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--list-tablets") { Diagnostics.listTablets() }
        let model = AppModel(preview: Snapshot.path != nil)
        _model = State(initialValue: model)
        SettingsWindow.shared.model = model
        SettingsWindow.classic.model = model
        SettingsWindow.terrain.model = model
        TuningWindow.terrain.model = model
        TuningWindow.dots.model = model
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
        Button("Terrain Settings…") { SettingsWindow.terrain.show() }
        Button("Classic Settings…") { SettingsWindow.classic.show() }
        Button("Terrain Tuning…") { TuningWindow.terrain.show() }
        Button("Dot Tuning…") { TuningWindow.dots.show() }
        Toggle("Pen Enabled", isOn: $model.settings.enabled)
        Divider()
        Button("Quit wdrive") { NSApp.terminate(nil) }
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

/// A settings window. wdrive is a menu bar app; while one of its windows is open it also
/// shows in the Dock and app switcher, like System Settings.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Style: String {
        /// The default: one page with the dot grid on the tablet, the rest behind the gear.
        case dots
        /// The same with the terrain on the tablet.
        case terrain
        /// The original window under the terrain header, in tabs.
        case classic
    }

    static let shared = SettingsWindow(style: .dots)
    static let terrain = SettingsWindow(style: .terrain)
    static let classic = SettingsWindow(style: .classic)
    var model: AppModel!
    let style: Style
    private var window: NSWindow?

    private init(style: Style) {
        self.style = style
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var defaultSize: NSSize {
        switch style {
        case .dots, .terrain: NSSize(width: SettingsLayout.compactWidth, height: SettingsLayout.compactHeight)
        case .classic: NSSize(width: SettingsLayout.width, height: SettingsLayout.height)
        }
    }

    func makeWindow(tab: SettingsTab = .mapping, page: CompactPage = .mapping) -> NSWindow {
        func hosting(_ view: some View) -> NSView {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            return host
        }
        let navigation = style == .classic ? nil : CompactNavigation(page: page)
        let host = switch style {
        case .dots: hosting(CompactSettingsView(model: model, navigation: navigation!, landscape: .dots))
        case .terrain: hosting(CompactSettingsView(model: model, navigation: navigation!, landscape: .terrain))
        case .classic: hosting(SettingsView(model: model, tab: tab))
        }
        let size = defaultSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        AppWindows.applyChrome(window)
        if let navigation { CompactTitlebar.install(in: window, navigation: navigation) }
        window.title = "wdrive"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: size.width, height: 420)
        let (model, watcher) = (model!, style.rawValue)
        _ = window.observeForeground { [weak window] in
            model.setLiveUpdates(window?.isInForeground == true, for: watcher)
        }
        let autosave = switch style {
        case .dots: "DotSettingsPanel"
        case .terrain: "CompactSettingsPanel"
        case .classic: "SettingsPanel"
        }
        if !window.setFrameUsingName(autosave) { window.center() }
        window.setFrameAutosaveName(autosave)
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.didClose(window)
    }
}

enum AppWindows {
    /// The content runs under a transparent title bar; the view draws the window's material and
    /// rounded corners itself. An empty toolbar puts the window buttons where macOS puts them in
    /// windows with a toolbar, clear of those corners.
    @MainActor static func applyChrome(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    /// From the window's top edge to the middle of its buttons, for lining up a header with them.
    static let buttonCenterY: CGFloat = 26

    /// Back to a menu bar app once the last window closes.
    @MainActor static func didClose(_ closing: NSWindow?) {
        let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// `--snapshot <file.png> [--page mapping|settings] [--terrain | --classic [--tab mapping|general|about]
/// | --tuning terrain|dots | --dots-panel] [--width <points>] [--height <points>] [--dark]`: renders a settings
/// window with sample data and quits.
enum Snapshot {
    static var path: String? { argument("--snapshot") }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func write(to path: String) {
        let args = CommandLine.arguments
        let settings = args.contains("--classic") ? SettingsWindow.classic : args.contains("--terrain") ? SettingsWindow.terrain : SettingsWindow.shared
        let window: NSWindow
        var size = settings.defaultSize
        if args.contains("--dots-panel") {
            window = DotsFullScreen.shared.makePanel()
            size = window.frame.size
        } else if let tuning = argument("--tuning").flatMap(Landscape.init) {
            window = TuningWindow.of(tuning).makeWindow()
            size = NSSize(width: 340, height: 640)
        } else {
            window = settings.makeWindow(tab: argument("--tab").flatMap(SettingsTab.init) ?? .mapping,
                                         page: argument("--page").flatMap(CompactPage.init) ?? .mapping)
        }
        // The landscapes read the app's.
        NSApp.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: Double(argument("--width") ?? "") ?? size.width,
                                     height: Double(argument("--height") ?? "") ?? size.height))
        if !args.contains("--onscreen") { window.setFrameOrigin(NSPoint(x: -4000, y: 0)) }
        window.orderFrontRegardless()
        // On screen it's the active window, with accent colours.
        if args.contains("--onscreen") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }
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
