import AppKit
import IOKit.hid
import Observation
import PenCore
import ServiceManagement

struct Settings: Equatable {
    var upper: ButtonAction = .rightClick
    var lower: ButtonAction = .middleClick
    var eraser: ButtonAction = .leftClick
    /// Fraction of full pressure needed to click.
    var tipThreshold = 0.10
    /// Click guard radius in tenths of a millimetre on the tablet, in `tapStabilityStep`s; 0 = off.
    var tapStability = 2.0
    static let tapStabilityRange = 0.0...6.0
    static let tapStabilityStep = 0.5
    /// "main", "all", or a `DisplayInfo.id`.
    var display = "main"
    var keepProportions = true
    var leftHanded = false
    /// Active area when proportions are off. Normalized, in the orientation the user sees.
    var area = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Active area when proportions are on: its centre and width are kept, the height follows the screen.
    var proportionalArea = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Custom was picked under Proportions: the area stays as drawn, even when it covers the whole tablet.
    var customArea = false
    /// Display origins as arranged for the tablet, by `DisplayInfo.id`. Empty = same as macOS.
    var layout: [String: CGPoint] = [:]
    var enabled = true
    var showMenuBarIcon = true
    var output = PenOutput.mouse
}

/// What apps see of the pen.
enum PenOutput: String, Codable, CaseIterable, Identifiable {
    /// Plain mouse events: clicks and drags.
    case mouse
    /// Tablet events too: pressure, tilt and which end of the pen is down.
    case tablet
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

extension Settings: Codable {
    enum CodingKeys: String, CodingKey {
        case upper, lower, eraser, tipThreshold, tapStability, display, keepProportions, leftHanded
        case area, proportionalArea, customArea, layout, enabled, showMenuBarIcon, output
    }

    /// Missing or unreadable keys fall back to defaults, so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        upper = value(.upper, d.upper)
        lower = value(.lower, d.lower)
        eraser = value(.eraser, d.eraser)
        tipThreshold = value(.tipThreshold, d.tipThreshold)
        let step = Self.tapStabilityStep
        tapStability = min((value(.tapStability, d.tapStability) / step).rounded() * step, Self.tapStabilityRange.upperBound)
        display = value(.display, d.display)
        keepProportions = value(.keepProportions, d.keepProportions)
        leftHanded = value(.leftHanded, d.leftHanded)
        area = value(.area, d.area)
        proportionalArea = value(.proportionalArea, d.proportionalArea)
        customArea = value(.customArea, d.customArea)
        layout = value(.layout, d.layout)
        enabled = value(.enabled, d.enabled)
        showMenuBarIcon = value(.showMenuBarIcon, d.showMenuBarIcon)
        output = value(.output, d.output)
    }
}

/// How the area fills the tablet: the displays' shape, the whole tablet, or drawn by hand.
enum AreaMode: String, CaseIterable, Identifiable {
    case displays, fill, custom
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    /// Real position in global display coordinates.
    let frame: CGRect
    let isMain: Bool
}

@Observable
final class AppModel {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            pushConfig()
        }
    }
    private(set) var displays: [DisplayInfo] = []
    /// Where the displays sit for the tablet without a custom layout: as macOS arranges them,
    /// with nearly aligned edges lined up.
    private(set) var defaultLayout: [String: CGPoint] = [:]
    private(set) var tablets: [TabletInfo] = []
    private(set) var live = LiveState()
    private(set) var inputMonitoringGranted = true
    private(set) var accessibilityGranted = true
    private(set) var otherDriverPIDs: [pid_t] = []
    private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    let driver = TabletDriver()
    let isPreview: Bool
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var liveWatchers = Set<String>()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private static let defaultsKey = "settings.v1"

    var tablet: TabletInfo? { tablets.first }
    var tabletSizeMM: CGSize { CGSize(width: tablet?.widthMM ?? 224, height: tablet?.heightMM ?? 148) }

    init(preview: Bool = false) {
        isPreview = preview
        // Settings saved before the rename live under the old bundle identifier.
        if !preview, let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
            ?? UserDefaults(suiteName: "express.looop.pendriver")?.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = preview ? Settings() : Self.importFromOpenTabletDriver() ?? Settings()
        }
        refreshDisplays()
        if preview {
            tablets = [TabletInfo(id: 1, name: "Wacom Intuos Pro M", widthMM: 224, heightMM: 148,
                                  pressureLevels: 8192, status: .active(exclusive: true))]
            live = LiveState(inRange: true, u: 0.31, v: 0.62, pressure: 0.42, tip: true, tiltX: 24, tiltY: -18)
            if displays.count > 1 { settings.display = "all" }
            return
        }

        driver.onTabletsChanged = { [weak self] tablets in
            guard let self else { return }
            self.tablets = tablets
            self.pushConfig()  // the proportional area depends on the tablet's shape
        }
        driver.start()
        save()
        pushConfig()

        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays()
            self?.pushConfig()
        }
    }

    // MARK: Live view

    /// Mirrors the pen state into the UI while any settings window is in the foreground.
    func setLiveUpdates(_ on: Bool, for watcher: String) {
        if on { liveWatchers.insert(watcher) } else { liveWatchers.remove(watcher) }
        let wanted = !liveWatchers.isEmpty
        guard !isPreview, wanted != (liveTimer != nil) else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        guard wanted else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = self.driver.live
            if state != self.live { self.live = state }
        }
    }

    /// Where the pen is in layout space, for the screen preview.
    var livePenLayoutPoint: CGPoint? {
        guard live.inRange else { return nil }
        return PenProcessor.layoutPoint(u: live.u, v: live.v, penConfig)
    }

    // MARK: Area

    /// The area the driver uses: the free area, or the proportional one fitted to the screen's shape.
    var effectiveArea: CGRect {
        settings.keepProportions ? fitted(settings.proportionalArea) : settings.area
    }

    /// Width/height of the area in normalized tablet units that keeps circles round on screen.
    var proportionalAspect: Double {
        let target = targetLayoutRect
        let tablet = tabletSizeMM
        return (target.width / max(target.height, 1)) * (tablet.height / tablet.width)
    }

    /// Keeps the centre and width, sets the height from the screen's shape; shrinks to fit if needed.
    private func fitted(_ r: CGRect) -> CGRect {
        let k = proportionalAspect
        var w = r.width, h = w / k
        if h > 1 { h = 1; w = k }
        if w > 1 { w = 1; h = 1 / k }
        return CGRect(x: min(max(r.midX - w / 2, 0), 1 - w), y: min(max(r.midY - h / 2, 0), 1 - h), width: w, height: h)
    }

    /// Drawing the area makes it a custom one.
    func setArea(_ r: CGRect) {
        var s = settings
        s.customArea = true
        if s.keepProportions { s.proportionalArea = r } else { s.area = r }
        settings = s
    }

    func resetArea() {
        var s = settings
        s.customArea = false
        if s.keepProportions { s.proportionalArea = Self.wholeTablet } else { s.area = Self.wholeTablet }
        settings = s
    }

    private static let wholeTablet = CGRect(x: 0, y: 0, width: 1, height: 1)

    var areaMode: AreaMode {
        get {
            let s = settings
            if !s.customArea {
                if s.keepProportions, s.proportionalArea == Self.wholeTablet { return .displays }
                if !s.keepProportions, s.area == Self.wholeTablet { return .fill }
            }
            return .custom
        }
        set {
            var s = settings
            switch newValue {
            case .displays:
                s.customArea = false
                s.keepProportions = true
                s.proportionalArea = Self.wholeTablet
            case .fill:
                s.customArea = false
                s.keepProportions = false
                s.area = Self.wholeTablet
            case .custom:
                // Starts from the area as it is now.
                s.customArea = true
            }
            settings = s
        }
    }

    /// Where a screen point (global display coordinates, top-left origin) lands on the tablet:
    /// normalized, in the orientation the user sees. Nil off the mapped displays.
    func tabletPoint(forScreen p: CGPoint) -> CGPoint? {
        let c = penConfig
        let layout: CGPoint
        if c.segments.isEmpty {
            guard c.target.contains(p) else { return nil }
            layout = p
        } else {
            guard let seg = c.segments.first(where: { $0.screen.contains(p) }) else { return nil }
            layout = CGPoint(x: p.x - seg.screen.minX + seg.layout.minX, y: p.y - seg.screen.minY + seg.layout.minY)
        }
        let sx = (layout.x - c.target.minX) / max(c.target.width - 1, 1)
        let sy = (layout.y - c.target.minY) / max(c.target.height - 1, 1)
        let area = PenProcessor.reach(c)
        return CGPoint(x: area.minX + sx * area.width, y: area.minY + sy * area.height)
    }

    /// Active area size on the tablet, in millimetres.
    var activeAreaMM: CGSize {
        let a = effectiveArea, t = tabletSizeMM
        return CGSize(width: a.width * t.width, height: a.height * t.height)
    }

    // MARK: Displays

    func layoutFrame(_ d: DisplayInfo) -> CGRect {
        CGRect(origin: settings.layout[d.id] ?? defaultLayout[d.id] ?? d.frame.origin, size: d.frame.size)
    }

    var layoutUnion: CGRect {
        displays.reduce(CGRect.null) { $0.union(layoutFrame($1)) }
    }

    var mappedDisplays: [DisplayInfo] {
        switch settings.display {
        case "all": return displays
        case let id:
            if let d = displays.first(where: { $0.id == id }) { return [d] }
            return displays.filter(\.isMain)
        }
    }

    /// What the tablet area covers, in layout space.
    var targetLayoutRect: CGRect {
        let r = mappedDisplays.reduce(CGRect.null) { $0.union(layoutFrame($1)) }
        return r.isNull || r.isEmpty ? CGDisplayBounds(CGMainDisplayID()) : r
    }

    var isLayoutCustomized: Bool { !settings.layout.isEmpty }

    /// Drops a display at `origin` (layout space), snapping it against the others.
    func moveDisplay(_ id: String, to origin: CGPoint) {
        guard let moving = displays.first(where: { $0.id == id }) else { return }
        let others = displays.filter { $0.id != id }
        let snapped = DisplayArrangement.snap(CGRect(origin: origin, size: moving.frame.size), to: others.map(layoutFrame))
        var layout: [String: CGPoint] = [:]
        for d in others { layout[d.id] = layoutFrame(d).origin }
        layout[id] = snapped.origin
        // Same relative positions as by default: nothing custom to remember.
        let origin = { (d: DisplayInfo) in self.defaultLayout[d.id] ?? d.frame.origin }
        let first = displays[0]
        let dx = layout[first.id]!.x - origin(first).x, dy = layout[first.id]!.y - origin(first).y
        let matchesDefault = displays.allSatisfy {
            abs(layout[$0.id]!.x - origin($0).x - dx) < 0.5 && abs(layout[$0.id]!.y - origin($0).y - dy) < 0.5
        }
        settings.layout = matchesDefault ? [:] : layout
    }

    func resetLayout() {
        settings.layout = [:]
    }

    private func refreshDisplays() {
        let main = CGMainDisplayID()
        var seen = Set<String>()
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            var key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            if !seen.insert(key).inserted { key += "-\(id)" }
            return DisplayInfo(id: key, name: screen.localizedName, frame: CGDisplayBounds(id), isMain: id == main)
        }
        let tidied = DisplayArrangement.tidy(displays.map(\.frame), keeping: displays.firstIndex(where: \.isMain) ?? 0)
        defaultLayout = Dictionary(uniqueKeysWithValues: zip(displays.map(\.id), tidied.map(\.origin)))
    }

    // MARK: Driver

    var penConfig: PenConfig {
        var c = PenConfig()
        c.area = effectiveArea
        c.leftHanded = settings.leftHanded
        c.target = targetLayoutRect
        c.segments = mappedDisplays.map { DisplaySegment(layout: layoutFrame($0), screen: $0.frame) }
        c.tipThreshold = settings.tipThreshold
        c.tapRadius = settings.tapStability / 10  // slider 0...6 → 0...0.6 mm
        c.tabletMM = tabletSizeMM
        c.doubleClickNs = UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
        c.upper = settings.upper
        c.lower = settings.lower
        c.eraser = settings.eraser
        c.tabletEvents = settings.output == .tablet
        return c
    }

    private func pushConfig() {
        guard !isPreview else { return }
        driver.update(penConfig)
        driver.setEnabled(settings.enabled)
    }

    private func save() {
        guard !isPreview, let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    // MARK: Permissions & environment

    private func poll() {
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if input && !inputMonitoringGranted { driver.retryFailedDevices() }
        if input != inputMonitoringGranted { inputMonitoringGranted = input }
        let post = CGPreflightPostEventAccess()
        if post != accessibilityGranted { accessibilityGranted = post }
        let others = ProcessList.pids(named: ["OpenTabletDriver.Daemon", "OpenTabletDriver.UX.MacOS"])
        if others != otherDriverPIDs { otherDriverPIDs = others }
        let login = SMAppService.mainApp.status == .enabled
        if login != openAtLogin { openAtLogin = login }
    }

    func quitOtherDriver() {
        otherDriverPIDs.forEach { kill($0, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.poll()
            self?.driver.retryFailedDevices()
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func openPrivacySettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: First-run import

    /// Carries over buttons, threshold, rotation and screen mapping from an existing OpenTabletDriver setup.
    static func importFromOpenTabletDriver() -> Settings? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/OpenTabletDriver/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = (root["Profiles"] as? [[String: Any]])?.first else { return nil }

        func values(_ plugin: [String: Any]?) -> [String: Any] {
            Dictionary((plugin?["Settings"] as? [[String: Any]] ?? []).compactMap { entry in
                (entry["Property"] as? String).map { ($0, entry["Value"] ?? NSNull()) }
            }, uniquingKeysWith: { a, _ in a })
        }
        func action(_ plugin: [String: Any]?) -> ButtonAction? {
            guard let plugin, plugin["Path"] as? String == "OpenTabletDriver.Desktop.Binding.MouseBinding" else { return nil }
            switch values(plugin)["Button"] as? String {
            case "Left": return .leftClick
            case "Right": return .rightClick
            case "Middle": return .middleClick
            case "Backward": return .back
            case "Forward": return .forward
            default: return nil
            }
        }

        var s = Settings()
        let filters = profile["Filters"] as? [[String: Any]] ?? []
        if let flip = filters.first(where: { $0["Path"] as? String == "Flip_Axes.Flip_Area_Axes" }), flip["Enable"] as? Bool == true {
            let v = values(flip)
            s.leftHanded = v["Flip_X"] as? Bool == true && v["Flip_Y"] as? Bool == true
        }
        if let bindings = profile["Bindings"] as? [String: Any] {
            if let t = bindings["TipActivationThreshold"] as? Double { s.tipThreshold = min(max(t / 100, 0.01), 0.5) }
            let pen = bindings["PenButtons"] as? [[String: Any]] ?? []
            if pen.count > 0, let a = action(pen[0]) { s.lower = a }
            if pen.count > 1, let a = action(pen[1]) { s.upper = a }
        }
        if let absolute = profile["AbsoluteModeSettings"] as? [String: Any] {
            s.keepProportions = absolute["LockAspectRatio"] as? Bool ?? true
            if let display = absolute["Display"] as? [String: Any], let w = display["Width"] as? Double, let h = display["Height"] as? Double {
                let all = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
                if w >= all.width - 1, h >= all.height - 1, NSScreen.screens.count > 1 { s.display = "all" }
            }
        }
        return s
    }
}

enum ProcessList {
    static func pids(named names: Set<String>) -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 64)
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0, proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
            return names.contains(String(cString: name))
        }.sorted()
    }
}
