import AppKit
import SwiftUI

/// The full-screen dots' own tuning. Until it's tuned, and after a reset, it's the preview's,
/// scaled up to a whole display.
@Observable
final class FullScreenDotStore {
    static let shared = FullScreenDotStore()

    /// Lengths grow by this much over the preview's tuning, so a whole display isn't more dots
    /// than are worth drawing.
    private static let scale = 2.0
    private static let defaultsKey = "dots.fullscreen.v1"

    static var base: DotTuning { DotStore.shared.tuning.scaled(by: scale).clamped }
    private static var isTuned: Bool { UserDefaults.standard.object(forKey: defaultsKey) != nil }

    var tuning: DotTuning {
        didSet {
            guard tuning != oldValue else { return }
            if tuning == Self.base {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            } else {
                tuning.save(defaultsKey: Self.defaultsKey)
            }
            onChange?(tuning)
        }
    }
    @ObservationIgnored var onChange: ((DotTuning) -> Void)?

    init() {
        tuning = Self.isTuned ? DotTuning(defaultsKey: Self.defaultsKey) : Self.base
    }

    /// Catches up with the preview, if this hasn't been tuned.
    func refresh() {
        if !Self.isTuned { tuning = Self.base }
    }
}

/// The dot grid over every display, edge to edge: space over the tablet preview opens it, Esc
/// closes it. Each display shows the pointer only while it's on that display, or over the gear
/// in its corner and the panel that opens, which live in windows of their own: clicks there
/// raise no hills.
@MainActor final class DotsFullScreen: NSObject, NSWindowDelegate {
    static let shared = DotsFullScreen()

    /// Over the menu bar and the Dock, yet under the menus that open from the panel.
    private static let level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 2)
    private static let controlsLevel = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 1)
    private static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    private static let gearSize: CGFloat = 28
    private static let margin: CGFloat = 16
    private static let panelSize = NSSize(width: 340, height: 640)

    private var windows: [NSWindow] = []
    private var gears: [NSWindow] = []
    private var panel: NSWindow?
    private var keyMonitor: Any?
    private var activeObserver: NSObjectProtocol?

    var isShown: Bool { !windows.isEmpty }

    func show(model: AppModel) {
        guard !isShown else { return }
        let store = FullScreenDotStore.shared
        store.refresh()
        let tuning = store.tuning
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = Window(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // On whichever Space is showing.
            window.level = Self.level
            window.collectionBehavior = Self.behavior
            window.isReleasedWhenClosed = false
            window.backgroundColor = TerrainPalette.adaptivePaper
            window.alphaValue = 0
            let view = DotView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.tuning = tuning
            view.pen = { model.driver.live }
            view.usesPenTilt = model.settings.output == .tablet
            view.interactive = false
            view.followsPointerInside = true
            // Off this display, nothing follows the pointer here.
            view.locate = { _ in nil }
            view.hidesPointer = { [weak self] _ in self?.isPointerOnControls == false }
            window.contentView = view
            windows.append(window)
            gears.append(makeGear(on: screen))
        }
        store.onChange = { [weak self] tuning in
            self?.windows.forEach { ($0.contentView as? DotView)?.tuning = tuning }
        }
        NSApp.activate()
        for window in windows {
            if window.frame.contains(mouse) { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        }
        gears.forEach { $0.orderFront(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            (windows + gears).forEach { $0.animator().alphaValue = 1 }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            self?.close()
            return nil
        }
        // Over every display, it would hide whatever the user switched to.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard isShown else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        FullScreenDotStore.shared.onChange = nil
        let closing = windows + gears
        windows = []
        gears = []
        panel?.close()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                // Taking the view out of its window gives the pointer back and stops its frames.
                for window in closing {
                    window.contentView = nil
                    window.orderOut(nil)
                }
            }
        }
    }

    /// The pointer stays visible over these, to aim at them.
    private var isPointerOnControls: Bool {
        let mouse = NSEvent.mouseLocation
        return (gears + (panel.map { [$0] } ?? [])).contains { $0.frame.contains(mouse) }
    }

    private func makeGear(on screen: NSScreen) -> NSWindow {
        let size = Self.gearSize
        let frame = NSRect(x: screen.frame.maxX - Self.margin - size, y: screen.frame.maxY - Self.margin - size,
                           width: size, height: size)
        let gear = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        gear.setFrame(frame, display: false)
        gear.level = Self.controlsLevel
        gear.collectionBehavior = Self.behavior
        gear.isReleasedWhenClosed = false
        gear.isOpaque = false
        gear.backgroundColor = .clear
        gear.hasShadow = false
        gear.alphaValue = 0
        gear.contentView = NSHostingView(rootView:
            TitlebarButton(symbol: "gearshape", active: false, help: "Tune the full screen dots") { [weak self] in
                self?.togglePanel(on: screen)
            }
            .frame(width: 16, height: 16)
            .frame(width: size, height: size))
        return gear
    }

    private func togglePanel(on screen: NSScreen) {
        if let panel {
            panel.close()
            return
        }
        let panel = makePanel()
        let height = min(Self.panelSize.height, screen.frame.height - 2 * Self.margin - Self.gearSize - 8)
        panel.setFrame(NSRect(x: screen.frame.maxX - Self.margin - Self.panelSize.width,
                              y: screen.frame.maxY - Self.margin - Self.gearSize - 8 - height,
                              width: Self.panelSize.width, height: height), display: false)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func makePanel() -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        AppWindows.applyChrome(panel)
        panel.title = "Full Screen Dots"
        panel.level = Self.controlsLevel
        panel.collectionBehavior = Self.behavior
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: SettingsLayout.width, height: 240)
        let host = NSHostingView(rootView: FullScreenTuningPanel())
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        // Back to the dots, for Esc.
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    /// Borderless, yet takes keys, for Esc.
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}

/// Everything about the full-screen dots, while looking at them.
private struct FullScreenTuningPanel: View {
    @Bindable private var store = FullScreenDotStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Under the title bar.
            Color.clear.frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These only change the full screen dots. Reset goes back to the look of the preview.")
                        .settingsDetailStyle()
                        .padding(.horizontal, 8)
                    TuningControls(tuning: $store.tuning, defaults: FullScreenDotStore.base)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .background(OverlayScroller())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusEffectDisabled()
        .background(SettingsLayout.paper)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
    }
}

extension DotTuning {
    /// Everything measured in points, `k` times as big.
    func scaled(by k: Double) -> DotTuning {
        var t = self
        t.spacing *= k
        t.dotSize *= k
        t.majorSize *= k
        t.groundRelief *= k
        t.groundScale *= k
        t.drift *= k
        t.hoverHeight *= k
        t.hoverRadius *= k
        t.push *= k
        t.sweep *= k
        t.hillHeight *= k
        t.hillRadius *= k
        return t
    }
}
