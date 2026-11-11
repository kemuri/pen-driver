import AppKit
import SwiftUI

/// Building blocks of the settings panel: rounded groups of compact rows in one scrolling
/// column, under a coloured header (the same look as Nearfield's settings).
enum SettingsLayout {
    /// The default window size; it is also the narrowest the window gets.
    static let width: CGFloat = 307
    static let height: CGFloat = 600
    /// The default size of the compact window.
    static let compactWidth: CGFloat = 364
    static let compactHeight: CGFloat = 763
    /// In a wide window the column stops growing and stays centred.
    static let maxContentWidth: CGFloat = 640
    static let headerHeight: CGFloat = 120
    /// The landscape's paper: the classic header, and all of the compact window.
    static let paper = Color(nsColor: TerrainPalette.adaptivePaper)
}

enum Theme {
    static let groupBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white.withAlphaComponent(0.045) : .black.withAlphaComponent(0.03)
    })
    static let separator = Color(nsColor: .separatorColor)
}

extension Text {
    func settingsTitleStyle(color: Color = .primary) -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    func settingsDetailStyle() -> some View {
        font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func settingsValueStyle() -> some View {
        font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

struct SettingsHeader: View {
    let title: String
    var pen: () -> LiveState = { LiveState() }
    var height = SettingsLayout.headerHeight
    var landscape = Landscape.terrain

    var body: some View {
        // The landscape also moves the window when dragged: the header fills the title bar.
        SettingsLayout.paper
            .overlay {
                switch landscape {
                case .terrain: TerrainSurface(tuning: TerrainStore.shared.tuning, pen: pen)
                case .dots: DotSurface(tuning: DotStore.shared.tuning, pen: pen)
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) {
                // Lined up with the column below it.
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color(nsColor: TerrainPalette.adaptiveInk))
                    .lineLimit(1)
                    .frame(maxWidth: SettingsLayout.maxContentWidth, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
            }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
                    .padding(.leading, 8)
                    .padding(.top, 8)
            } else {
                Color.clear.frame(height: 4)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(Theme.groupBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

/// A title with an optional explanation underneath, and a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var height: CGFloat = 42
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).settingsTitleStyle()
                Spacer(minLength: 8)
                control
            }
            if let detail {
                Text(detail).settingsDetailStyle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, detail == nil ? 8 : 10)
        .frame(minHeight: height, alignment: .center)
    }
}

struct ToggleSettingRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail, height: 46) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
    }
}

struct PickerSettingRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        SettingRow(title: title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
        }
    }
}

struct InfoSettingRow: View {
    let title: String
    let value: String

    var body: some View {
        SettingRow(title: title, height: 36) {
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A slider under its title, with the current value on the right and symbols at both ends.
struct SliderSettingRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Snaps to steps of this, and shows them as tick marks.
    var step: Double?
    var lowSymbol: String?
    var highSymbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).settingsTitleStyle()
                Spacer()
                Text(valueText).settingsValueStyle()
            }
            HStack(spacing: 7) {
                if let lowSymbol { Image(systemName: lowSymbol).sliderEndStyle() }
                slider
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(height: 30)
                if let highSymbol { Image(systemName: highSymbol).sliderEndStyle() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 66)
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

private extension Image {
    func sliderEndStyle() -> some View {
        font(.system(size: 10, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 24)
    }
}

/// A coloured status line above the groups.
struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Window

/// The system window material picks up the wallpaper tint like System Settings does;
/// a flat window background colour would not.
struct WindowMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Scrolling

/// Fades content out under the header once the column has scrolled.
struct ProgressiveTopFade: View {
    let isVisible: Bool

    var body: some View {
        // Fade into the window material itself so the edge matches the background.
        WindowMaterialBackground()
            .mask {
                LinearGradient(colors: [.black.opacity(0.98), .black.opacity(0.72), .black.opacity(0.22), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .opacity(isVisible ? 1 : 0)
            .frame(height: 74)
    }
}

/// Keeps the enclosing NSScrollView's scroller thin and floating, even when macOS would show the
/// wide always-visible one (a mouse plugged in, or "Show scroll bars: Always").
struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }
    func updateNSView(_ nsView: ScrollerView, context: Context) { nsView.applySoon() }

    final class ScrollerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observer == nil {
                // AppKit switches every scroll view back when the system preference changes.
                observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applySoon() }
                }
            }
            applySoon()
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func applySoon() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
                scrollView.scrollerStyle = .overlay
            }
        }
    }
}

/// Reports the enclosing NSScrollView's scroll offset.
struct ScrollOffsetObserver: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        context.coordinator.onChange = onChange
        nsView.coordinator = context.coordinator
        nsView.attachSoon()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator {
        var onChange: (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView, scrollView !== self.scrollView else {
                update()
                return
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                              object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            update()
        }

        func update() {
            onChange(max(0, scrollView?.contentView.bounds.origin.y ?? 0))
        }
    }

    final class ObserverView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachSoon()
        }

        func attachSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                coordinator?.attach(from: self)
            }
        }
    }
}
