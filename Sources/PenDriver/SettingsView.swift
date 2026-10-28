import PenCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case tablet, mapping, pen, general

    var id: Self { self }

    var title: String {
        switch self {
        case .tablet: "Tablet"
        case .mapping: "Mapping"
        case .pen: "Pen"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .tablet: "pencil.and.scribble"
        case .mapping: "display.2"
        case .pen: "pencil.tip"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State var selection: Pane? = .mapping

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                TabletStatusRow(model: model)
                    .tag(Pane.tablet)
                    .padding(.vertical, 6)
                Section {
                    ForEach([Pane.mapping, .pen, .general]) { pane in
                        // Not a Label: the sidebar restyles label icons, which would undo the tile look.
                        HStack(spacing: 8) {
                            IconTile(symbol: pane.symbol)
                            Text(pane.title)
                        }
                        .tag(pane)
                    }
                }
            }
            .navigationSplitViewColumnWidth(220)
        } detail: {
            Group {
                switch selection ?? .mapping {
                case .tablet: TabletPane(model: model)
                case .mapping: MappingPane(model: model)
                case .pen: PenPane(model: model)
                case .general: GeneralPane(model: model)
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .navigationTitle((selection ?? .mapping).title)
        }
        .onChange(of: selection, initial: true) { SettingsWindow.shared.setPane(selection ?? .mapping) }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { model.setLiveUpdates(true) }
        .onDisappear { model.setLiveUpdates(false) }
    }
}

// MARK: - Sidebar

private struct TabletStatusRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.tablet?.name ?? "No Tablet").font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var status: (text: String, color: Color) {
        if !model.otherDriverPIDs.isEmpty || !model.inputMonitoringGranted || !model.accessibilityGranted {
            return ("Needs attention", .orange)
        }
        guard let tablet = model.tablet else { return ("Not connected", .secondary) }
        switch tablet.status {
        case .active: return model.settings.enabled ? ("Connected", .green) : ("Paused", .secondary)
        case .disabled: return ("Paused", .secondary)
        case .needsPermission, .failed: return ("Needs attention", .orange)
        }
    }
}

/// A monochrome glyph on a neutral tile, like the System Settings sidebar.
struct IconTile: View {
    let symbol: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .foregroundStyle(Color(nsColor: .labelColor))
            .frame(width: 13, height: 13)
            .frame(width: 22, height: 22)
            .background {
                tile.fill(dark ? Color.white.opacity(0.07) : Color.white)
                    .overlay(tile.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0), .white.opacity(dark ? 0.03 : 0)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.15), radius: 0.5, y: 0.5)
            }
    }
}

// MARK: - Tablet

private struct TabletPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Notices(model: model)

            Section {
                if let tablet = model.tablet {
                    LabeledContent("Model", value: tablet.name)
                    LabeledContent("Surface", value: String(format: "%.0f × %.0f mm", tablet.widthMM, tablet.heightMM))
                    if let levels = tablet.pressureLevels { LabeledContent("Pressure levels", value: "\(levels)") }
                    LabeledContent("Access", value: access(tablet.status))
                } else {
                    Text("Connect a Wacom or XP-Pen tablet. It's picked up automatically.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Pen enabled", isOn: $model.settings.enabled)
            } footer: {
                FooterText("When off, Pen Driver lets go of the tablet completely.")
            }
        }
    }

    private func access(_ status: TabletInfo.Status) -> String {
        switch status {
        case .active(exclusive: true): "Exclusive"
        case .active(exclusive: false): "Shared with another app"
        case .disabled: "Paused"
        case .needsPermission: "Waiting for Input Monitoring"
        case let .failed(code): String(format: "Couldn’t open (0x%08x)", code)
        }
    }
}

private struct Notices: View {
    let model: AppModel

    var body: some View {
        let showOther = !model.otherDriverPIDs.isEmpty
        let showInput = !model.inputMonitoringGranted
        let showAccess = !model.accessibilityGranted
        let shared = model.tablets.contains { $0.status == .active(exclusive: false) }
        if showOther || showInput || showAccess || shared {
            Section {
                if showOther {
                    Notice(text: "OpenTabletDriver is running. Both drivers would fight over the pen.",
                           button: "Quit It") { model.quitOtherDriver() }
                }
                if showInput {
                    Notice(text: "Allow Input Monitoring so Pen Driver can read the tablet.",
                           button: "Open Settings") { AppModel.openPrivacySettings("Privacy_ListenEvent") }
                }
                if showAccess {
                    Notice(text: "Allow Accessibility so Pen Driver can move the pointer.",
                           button: "Open Settings") { AppModel.openPrivacySettings("Privacy_Accessibility") }
                }
                if shared && !showOther {
                    Notice(text: "Couldn’t get exclusive access to the tablet. Another app may also be using it.",
                           button: nil, action: {})
                }
            }
        }
    }
}

// MARK: - Mapping

private struct MappingPane: View {
    @Bindable var model: AppModel
    @State private var arranging = false

    var body: some View {
        Form {
            Section {
                TabletSurface(model: model)
                    .aspectRatio(model.tabletSizeMM.width / model.tabletSizeMM.height, contentMode: .fit)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                Picker("Map tablet to", selection: $model.settings.display) {
                    Text("Main display (with the menu bar)").tag("main")
                    if model.displays.count > 1 {
                        ForEach(model.displays) { Text($0.name).tag($0.id) }
                        Text("All displays").tag("all")
                    }
                }
                if model.displays.count > 1, model.settings.display == "all" {
                    LabeledContent("Display arrangement") {
                        Button("Arrange…") { arranging = true }
                            .popover(isPresented: $arranging, arrowEdge: .bottom) { ArrangeDisplays(model: model) }
                    }
                }
            } header: {
                Text(model.tablet?.name ?? "Tablet")
            } footer: {
                let mm = model.activeAreaMM
                FooterText(String(format: "The dashed box is the active area (%.0f × %.0f mm) and shows where each screen lands. Drag it to move, drag a corner to resize, double-click to reset.", mm.width, mm.height))
            }

            Section {
                Toggle("Keep proportions (circles stay round)", isOn: $model.settings.keepProportions)
                Toggle("Left-handed (tablet turned around)", isOn: $model.settings.leftHanded)
            } footer: {
                if model.settings.keepProportions, model.activeAreaMM.height < model.tabletSizeMM.height * 0.5 {
                    FooterText("The screens are much wider than the tablet, so keeping proportions leaves a narrow strip. Turn proportions off to use the whole tablet, or map to a single display.")
                }
            }
        }
    }
}

private struct ArrangeDisplays: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arrange Displays").font(.headline)
            DisplayMapView(model: model)
            Text("Drag displays to set how the tablet spans them. This doesn’t change your macOS arrangement.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isLayoutCustomized {
                Button("Use macOS Arrangement") { model.resetLayout() }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Pen

private struct PenPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    PressureBar(pressure: model.live.inRange ? model.live.pressure : 0, threshold: model.settings.tipThreshold)
                    HStack(spacing: 8) {
                        Chip(title: "Tip", active: model.live.tip)
                        Chip(title: "Lower", active: model.live.lower)
                        Chip(title: "Upper", active: model.live.upper)
                        Chip(title: "Eraser", active: model.live.eraser)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Try it")
            } footer: {
                FooterText("Press the pen and its buttons to see them light up.")
            }

            Section("Pen buttons") {
                actionPicker("Upper button", $model.settings.upper)
                actionPicker("Lower button", $model.settings.lower)
                actionPicker("Eraser", $model.settings.eraser)
            }

            Section {
                labeledSlider("Tip feel", value: $model.settings.tipThreshold, in: 0.01...0.5, low: "Soft", high: "Firm")
                labeledSlider("Tap stability", value: $model.settings.tapStability, in: 0...20, low: "Off", high: "Strong")
            } header: {
                Text("Tip")
            } footer: {
                FooterText("Tip feel: how hard to press before it clicks (the mark on the pressure bar). Tap stability: how far the pen can wobble during a click before it becomes a drag.")
            }
        }
    }

    private func actionPicker(_ title: String, _ selection: Binding<ButtonAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ButtonAction.allCases) { Text($0.title).tag($0) }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, low: String, high: String) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 250)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Toggle("Show in menu bar", isOn: $model.settings.showMenuBarIcon)
            } footer: {
                FooterText("With the menu bar icon hidden, open Pen Driver again from Finder or Spotlight to get back here.")
            }

            Section {
                LabeledContent("Pen Driver \(Bundle.main.shortVersion)") {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
    }
}

private extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

// MARK: - Components

struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Notice: View {
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button { Button(button, action: action) }
        }
    }
}

struct PressureBar: View {
    let pressure: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(pressure >= threshold ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: geo.size.width * pressure)
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: 10)
                    .offset(x: geo.size.width * threshold - 1)
            }
        }
        .frame(height: 6)
    }
}

struct Chip: View {
    let title: String
    let active: Bool

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.08)))
    }
}
