import PenCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case mapping, general, about
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// The settings under a coloured header, one tab at a time in a scrolling column.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tab: SettingsTab
    @State private var showsTopFade = false

    init(model: AppModel, tab: SettingsTab = .mapping) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "wdrive", pen: { model.driver.live })
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: SettingsLayout.maxContentWidth)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 2)
            ZStack(alignment: .top) {
                ScrollView {
                    ScrollOffsetObserver { offset in
                        if offset > 12, !showsTopFade { showsTopFade = true }
                        else if offset <= 1, showsTopFade { showsTopFade = false }
                    }
                    .frame(width: 0, height: 0)

                    VStack(alignment: .leading, spacing: 8) {
                        switch tab {
                        case .mapping:
                            TabletStatus(model: model)
                            Notices(model: model)
                            MappingSection(model: model)
                        case .general:
                            TabletStatus(model: model)
                            Notices(model: model)
                            GeneralGroup(model: model)
                            PenSection(model: model)
                        case .about:
                            AboutHeader()
                            TabletSection(model: model)
                        }
                    }
                    .frame(maxWidth: SettingsLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .background(OverlayScroller())
                }
                // Each tab starts at the top.
                .id(tab)
                ProgressiveTopFade(isVisible: showsTopFade)
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { WindowMaterialBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
    }
}

// MARK: - Status

struct TabletStatus: View {
    let model: AppModel

    var body: some View {
        let s = status
        StatusPill(text: s.text, symbol: s.symbol, color: s.color)
    }

    private var status: (text: String, symbol: String, color: Color) {
        let attention = (text: "Needs attention", symbol: "exclamationmark.triangle.fill", color: Color.orange)
        if !model.otherDriverPIDs.isEmpty || !model.inputMonitoringGranted || !model.accessibilityGranted { return attention }
        guard let tablet = model.tablet else { return ("No tablet connected", "exclamationmark.triangle.fill", .yellow) }
        switch tablet.status {
        case .active:
            return model.settings.enabled ? ("\(tablet.name) connected", "checkmark.circle.fill", .green)
                                          : ("\(tablet.name) paused", "pause.circle.fill", .secondary)
        case .disabled: return ("\(tablet.name) paused", "pause.circle.fill", .secondary)
        case .needsPermission, .failed: return attention
        }
    }
}

struct Notices: View {
    let model: AppModel

    var body: some View {
        let showOther = !model.otherDriverPIDs.isEmpty
        let showInput = !model.inputMonitoringGranted
        let showAccess = !model.accessibilityGranted
        let shared = !showOther && model.tablets.contains { $0.status == .active(exclusive: false) }
        if showOther || showInput || showAccess || shared {
            SettingsGroup {
                if showOther {
                    NoticeRow(text: "OpenTabletDriver is running. Both drivers would fight over the pen.",
                              button: "Quit It") { model.quitOtherDriver() }
                }
                if showInput {
                    if showOther { SettingsDivider() }
                    NoticeRow(text: "Allow Input Monitoring so wdrive can read the tablet.",
                              button: "Open Settings") { AppModel.openPrivacySettings("Privacy_ListenEvent") }
                }
                if showAccess {
                    if showOther || showInput { SettingsDivider() }
                    NoticeRow(text: "Allow Accessibility so wdrive can move the pointer.",
                              button: "Open Settings") { AppModel.openPrivacySettings("Privacy_Accessibility") }
                }
                if shared {
                    if showInput || showAccess { SettingsDivider() }
                    NoticeRow(text: "Couldn’t get exclusive access to the tablet. Another app may also be using it.")
                }
            }
        }
    }
}

private struct NoticeRow: View {
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                Button(button, action: action).controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - General

struct GeneralGroup: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsSection {
            SettingsGroup {
                ToggleSettingRow(title: "Pen enabled", detail: "When off, wdrive lets go of the tablet completely.",
                                 isOn: $model.settings.enabled)
                SettingsDivider()
                ToggleSettingRow(title: "Open at login",
                                 isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                SettingsDivider()
                ToggleSettingRow(title: "Show in menu bar", detail: "Open wdrive again to show this window.",
                                 isOn: $model.settings.showMenuBarIcon)
                SettingsDivider()
                SettingRow(title: "Quit wdrive") {
                    Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Mapping

private struct MappingSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsSection("Mapping") {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    TabletSurface(model: model)
                        .aspectRatio(model.tabletSizeMM.width / model.tabletSizeMM.height, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    let mm = model.activeAreaMM
                    Text(String(format: "Active area %.0f × %.0f mm. Drag it to move, drag a corner to resize, double-click to reset.",
                                mm.width, mm.height))
                        .settingsDetailStyle()
                }
                .padding(12)

                SettingsDivider()
                MapToRow(model: model)
                if model.showsArrangement {
                    SettingsDivider()
                    ArrangeDisplaysRow(model: model)
                }

                SettingsDivider()
                ToggleSettingRow(title: "Keep proportions", detail: proportionsDetail, isOn: $model.settings.keepProportions)
                SettingsDivider()
                ToggleSettingRow(title: "Left-handed", detail: "The tablet turned around.", isOn: $model.settings.leftHanded)
            }
        }
    }

    private var proportionsDetail: String {
        if model.settings.keepProportions, model.activeAreaMM.height < model.tabletSizeMM.height * 0.5 {
            return "The screens are much wider than the tablet, so this leaves a narrow strip. Turn it off to use the whole tablet, or map to one display."
        }
        return "Circles stay round."
    }
}

struct MapToRow: View {
    @Bindable var model: AppModel

    var body: some View {
        PickerSettingRow(title: "Map to", selection: $model.settings.display) {
            Text("Main display").tag("main")
            if model.displays.count > 1 {
                ForEach(model.displays) { Text($0.name).tag($0.id) }
                Text("All displays").tag("all")
            }
        }
    }
}

extension AppModel {
    /// Arranging only matters when the tablet spans more than one display.
    var showsArrangement: Bool { displays.count > 1 && settings.display == "all" }
}

struct ArrangeDisplaysRow: View {
    let model: AppModel
    @State private var arranging = false

    var body: some View {
        SettingRow(title: "Display arrangement") {
            Button("Arrange…") { arranging = true }
                .controlSize(.small)
                .popover(isPresented: $arranging, arrowEdge: .bottom) { ArrangeDisplays(model: model) }
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

struct PenSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsSection("Pen") {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        PressureBar(pressure: model.live.inRange ? model.live.pressure : 0, threshold: model.settings.tipThreshold)
                        Chip(title: pressed.title, active: pressed.active)
                            .frame(width: 63)
                    }
                    // In place of the hint, so the column doesn't jump when the pen comes near.
                    if model.live.inRange {
                        Text(String(format: "tilt %+.0f° %+.0f°", model.live.tiltX, model.live.tiltY))
                            .settingsValueStyle()
                    } else {
                        Text("Press the pen and its buttons to try them.").settingsDetailStyle()
                    }
                }
                .padding(12)

                SettingsDivider()
                SliderSettingRow(title: "Tip feel", valueText: String(format: "%.0f%%", model.settings.tipThreshold * 100),
                                 value: $model.settings.tipThreshold, range: 0.01...0.5,
                                 lowSymbol: "circle", highSymbol: "circle.fill")
                SettingsDivider()
                SliderSettingRow(title: "Tap stability", valueText: tapStabilityText,
                                 value: $model.settings.tapStability, range: Settings.tapStabilityRange,
                                 step: Settings.tapStabilityStep, lowSymbol: "circle.dotted", highSymbol: "smallcircle.filled.circle")
                Text("Tip feel is how hard to press before it clicks (the mark on the pressure bar). Tap stability is how far the pen can wobble during a click before it becomes a drag.")
                    .settingsDetailStyle()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                SettingsDivider()
                SettingRow(title: "Mode", detail: modeDetail) {
                    Picker("Mode", selection: $model.settings.output) {
                        ForEach(PenOutput.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                SettingsDivider()
                actionPicker("Upper button", $model.settings.upper)
                SettingsDivider()
                actionPicker("Lower button", $model.settings.lower)
                SettingsDivider()
                actionPicker("Eraser", $model.settings.eraser)
            }
        }
    }

    /// The button held down, or the tip, which is what the chip names while nothing is pressed.
    private var pressed: (title: String, active: Bool) {
        let live = model.live
        if live.eraser { return ("Eraser", true) }
        if live.upper { return ("Upper", true) }
        if live.lower { return ("Lower", true) }
        return ("Tip", live.tip)
    }

    private var modeDetail: String {
        switch model.settings.output {
        case .mouse: "Apps see a mouse: clicks and drags."
        case .tablet: "Drawing apps also get pressure, tilt and the eraser end."
        }
    }

    private var tapStabilityText: String {
        let mm = model.settings.tapStability / 10
        return mm == 0 ? "Off" : String(format: "%.2f mm", mm)
    }

    private func actionPicker(_ title: String, _ selection: Binding<ButtonAction>) -> some View {
        PickerSettingRow(title: title, selection: selection) {
            ForEach(ButtonAction.allCases) { Text($0.title).tag($0) }
        }
    }
}

// MARK: - About

struct AboutHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("wdrive").font(.system(size: 15, weight: .semibold))
                Text("Version \(Bundle.main.shortVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("A low-latency driver for Wacom and XP-Pen tablets.")
                    .settingsDetailStyle()
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TabletSection: View {
    let model: AppModel

    var body: some View {
        SettingsSection("Tablet") {
            SettingsGroup {
                if let tablet = model.tablet {
                    InfoSettingRow(title: "Model", value: tablet.name)
                    SettingsDivider()
                    InfoSettingRow(title: "Surface", value: String(format: "%.0f × %.0f mm", tablet.widthMM, tablet.heightMM))
                    if let levels = tablet.pressureLevels {
                        SettingsDivider()
                        InfoSettingRow(title: "Pressure levels", value: "\(levels)")
                    }
                    SettingsDivider()
                    InfoSettingRow(title: "Access", value: access(tablet.status))
                } else {
                    Text("Connect a Wacom or XP-Pen tablet. It’s picked up automatically.")
                        .settingsDetailStyle()
                        .padding(12)
                }
            }
        }
    }

    private func access(_ status: TabletInfo.Status) -> String {
        switch status {
        case .active(exclusive: true): "Exclusive"
        case .active(exclusive: false): "Shared"
        case .disabled: "Paused"
        case .needsPermission: "Waiting for permission"
        case let .failed(code): String(format: "Failed (0x%08x)", code)
        }
    }
}

private extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

// MARK: - Live pen

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
        .frame(height: 10)
    }
}

struct Chip: View {
    let title: String
    let active: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.08)))
    }
}
