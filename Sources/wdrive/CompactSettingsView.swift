import AppKit
import SwiftUI

enum CompactPage: String {
    /// The tablet, its mapping and the pen.
    case mapping
    /// Behind the gear: about, general and the pen buttons.
    case settings
}

/// Which page the compact window shows. The gear in the title bar and the page below share it.
@Observable final class CompactNavigation {
    var page: CompactPage
    init(page: CompactPage = .mapping) { self.page = page }
}

/// The default settings window: everything about the tablet on one page, the rest behind the
/// gear in the title bar. The tablet shows the dot grid, or in the terrain window, the terrain.
struct CompactSettingsView: View {
    @Bindable var model: AppModel
    let navigation: CompactNavigation
    var landscape = Landscape.dots

    var body: some View {
        VStack(spacing: 0) {
            // Under the title bar, which moves the window and holds the gear.
            Color.clear.frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch navigation.page {
                    case .mapping:
                        TabletStatus(model: model)
                        Notices(model: model)
                        TabletSurface(model: model, style: landscape == .dots ? .dots : .terrain)
                        CompactMappingGroup(model: model)
                        PenSection(model: model)
                    case .settings:
                        AboutHeader()
                        GeneralGroup(model: model)
                        TabletSection(model: model)
                        SettingsSection {
                            SettingsGroup {
                                SettingRow(title: landscape == .dots ? "Tune the dots" : "Tune the terrain") {
                                    Button("Open") { TuningWindow.of(landscape).show() }.controlSize(.small)
                                }
                                SettingsDivider()
                                SettingRow(title: landscape == .dots ? "Terrain settings" : "Dot settings") {
                                    Button("Open") { (landscape == .dots ? SettingsWindow.terrain : SettingsWindow.shared).show() }
                                        .controlSize(.small)
                                }
                                SettingsDivider()
                                SettingRow(title: "Classic settings") {
                                    Button("Open") { SettingsWindow.classic.show() }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: SettingsLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .background(OverlayScroller())
            }
            // Each page starts at the top.
            .id(navigation.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusEffectDisabled()
        .background(SettingsLayout.paper)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
    }
}

/// The gear and the wordmark, at the right end of the title bar; the window draws its buttons
/// at the left. They sit in the title bar itself: the toolbar that puts the window buttons in
/// their usual place takes every click over the content under it.
struct CompactTitlebar: View {
    let navigation: CompactNavigation

    var body: some View {
        let showsSettings = navigation.page == .settings
        HStack(spacing: 8) {
            TitlebarButton(symbol: showsSettings ? "gearshape.fill" : "gearshape", active: showsSettings,
                           help: showsSettings ? "Back to the tablet" : "Settings") {
                navigation.page = showsSettings ? .mapping : .settings
            }
            .frame(width: 16, height: 16)
            Wordmark()
        }
        .frame(height: 21)
        // As far in from the edge as the window buttons are.
        .padding(.trailing, 19)
        // Level with them: the title bar sets this lower.
        .padding(.bottom, 14)
    }

    /// Adds it to a window's title bar, level with the window buttons.
    @MainActor static func install(in window: NSWindow, navigation: CompactNavigation) {
        let host = NSHostingView(rootView: CompactTitlebar(navigation: navigation))
        host.frame.size = host.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }
}

/// A symbol button that works in the title bar. The title bar moves the window on any click
/// whose view lets it, and SwiftUI's buttons do; this one doesn't, like the classic header's terrain.
struct TitlebarButton: NSViewRepresentable {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.refusesFirstResponder = true
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.contentTintColor = active ? .labelColor : .secondaryLabelColor
        button.toolTip = help
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc @MainActor func clicked() { action() }
    }

    final class Control: NSButton {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// WDRIVER, each letter a weight lighter than the last.
private struct Wordmark: View {
    var body: some View {
        let size: CGFloat = 17.915
        let w = Text("W").font(.system(size: size, weight: .black)).italic().tracking(-2.08)
        let d = Text("D").font(.system(size: size, weight: .bold)).tracking(-1.12)
        let r = Text("R").font(.system(size: size, weight: .semibold)).tracking(-0.7166)
        let i = Text("I").font(.system(size: size, weight: .medium)).tracking(-0.7166)
        let v = Text("V").font(.system(size: size, weight: .regular)).tracking(-0.7166)
        let e = Text("E").font(.system(size: size, weight: .light)).tracking(-0.7166)
        let r2 = Text("R").font(.system(size: size, weight: .thin))
        Text("\(w)\(d)\(r)\(i)\(v)\(e)\(r2)")
            .foregroundStyle(Color(nsColor: TerrainPalette.adaptiveInk))
            .opacity(0.2)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("wdrive")
    }
}

private struct CompactMappingGroup: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsGroup {
            MapToRow(model: model)
            SettingRow(title: "Proportions") {
                Picker("Proportions", selection: Binding(get: { model.areaMode }, set: { model.areaMode = $0 })) {
                    ForEach(AreaMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if model.areaMode == .custom {
                SettingsDivider()
                ToggleSettingRow(title: "Keep proportions",
                                 detail: "Drag the area on the tablet to move it, drag an edge or corner to resize, double-click to reset.",
                                 isOn: $model.settings.keepProportions)
            }
            if model.showsArrangement {
                SettingsDivider()
                ArrangeDisplaysRow(model: model)
            }
            SettingsDivider()
            ToggleSettingRow(title: "Left-handed", detail: "The tablet turned around.", isOn: $model.settings.leftHanded)
        }
    }
}
