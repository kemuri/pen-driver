import AppKit
import SwiftUI

/// Live controls for a landscape, the terrain or the dots, with its own copy to play with.
@MainActor
final class TuningWindow: NSObject, NSWindowDelegate {
    static let terrain = TuningWindow(landscape: .terrain)
    static let dots = TuningWindow(landscape: .dots)
    static func of(_ landscape: Landscape) -> TuningWindow { landscape == .dots ? dots : terrain }

    var model: AppModel!
    let landscape: Landscape
    private var window: NSWindow?

    private init(landscape: Landscape) {
        self.landscape = landscape
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func makeWindow() -> NSWindow {
        let model = model!
        let pen = { model.driver.live }
        func hosting(_ view: some View) -> NSView {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            return host
        }
        let host = switch landscape {
        case .terrain:
            hosting(TuningView(
                tuning: Bindable(TerrainStore.shared).tuning, title: "Terrain", landscape: .terrain, pen: pen,
                note: "The circle follows the pointer across all your displays. Press the header to raise a hill: pen pressure sets how big it gets, and a Force Touch trackpad works too."))
        case .dots:
            hosting(TuningView(
                tuning: Bindable(DotStore.shared).tuning, title: "Dots", landscape: .dots, pen: pen,
                note: "The dots stir as the pointer passes over them, wherever it is on your displays. Press the header to raise a hill: pen pressure sets how big it gets, and a Force Touch trackpad works too."))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Same chrome as the settings window.
        AppWindows.applyChrome(window)
        window.title = landscape == .dots ? "Dots" : "Terrain"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: SettingsLayout.width, height: 420)
        let autosave = landscape == .dots ? "DotsPanel" : "TerrainPanel"
        if !window.setFrameUsingName(autosave) { window.center() }
        window.setFrameAutosaveName(autosave)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.didClose(window)
    }
}

struct TuningView<Tuning: Tunable>: View {
    @Binding var tuning: Tuning
    let title: String
    let landscape: Landscape
    let pen: () -> LiveState
    let note: String
    @AppStorage private var previewHeight: Double
    @State private var dragStartHeight: Double?

    init(tuning: Binding<Tuning>, title: String, landscape: Landscape, pen: @escaping () -> LiveState, note: String) {
        _tuning = tuning
        self.title = title
        self.landscape = landscape
        self.pen = pen
        self.note = note
        _previewHeight = AppStorage(wrappedValue: 180, "\(landscape.rawValue)PreviewHeight")
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: title, pen: pen, height: previewHeight, landscape: landscape)
            resizeHandle
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note)
                        .settingsDetailStyle()
                        .padding(.horizontal, 8)
                    TuningControls(tuning: $tuning)
                }
                .frame(maxWidth: SettingsLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .background(OverlayScroller())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { WindowMaterialBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
    }

    /// Drag to make the preview taller or shorter.
    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStartHeight ?? previewHeight
                    dragStartHeight = start
                    previewHeight = min(max(start + drag.translation.height, 80), 600)
                }
                .onEnded { _ in dragStartHeight = nil })
    }
}

/// Every parameter, in its sections, and the way back to the defaults.
struct TuningControls<Tuning: Tunable>: View {
    @Binding var tuning: Tuning
    var defaults = Tuning()

    var body: some View {
        ForEach(Tuning.sections, id: \.title) { section in
            SettingsSection(section.title) {
                SettingsGroup {
                    ForEach(Array(section.parameters.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { SettingsDivider() }
                        control(p)
                    }
                }
            }
        }
        SettingsSection {
            SettingsGroup {
                SettingRow(title: "Defaults") {
                    Button("Reset") { tuning = defaults }
                        .controlSize(.small)
                        .disabled(tuning == defaults)
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ p: TuningParameter<Tuning>) -> some View {
        let value = Binding(get: { tuning[keyPath: p.keyPath] }, set: { tuning[keyPath: p.keyPath] = $0 })
        if let choices = p.choices {
            PickerSettingRow(title: p.title, selection: value) {
                ForEach(choices.indices, id: \.self) { Text(choices[$0]).tag(Double($0)) }
            }
        } else {
            SliderSettingRow(title: p.title, valueText: p.format(value.wrappedValue), value: value,
                             range: p.range, step: p.step)
        }
    }
}
