import AppKit
import Carbon.HIToolbox
import CoreAudio

// Desktop mode (`--desktop`, launched by player/desk): a macOS display shown
// as a panel floating in the headset instead of a video. This file holds the
// mode's coordinator; capture is in screen_capture.swift, the virtual display
// and the display arrangement in virtual_display.swift.

// Global hotkeys, kept in one place so they are easy to change. Carbon's
// RegisterEventHotKey works while another app has keyboard focus and, unlike
// a CGEventTap, needs no Accessibility permission. Size/distance/mode keys
// are temporary until the settings panel (M5)
enum DesktopHotKey: UInt32, CaseIterable {
    case emergencyQuit = 1
    case narrower, wider, nearer, farther, resetPanel
    case flatter, curvier
    case cycleMode

    private static let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    var keyCode: UInt32 {
        switch self {
        case .emergencyQuit: return UInt32(kVK_ANSI_Q)
        case .narrower: return UInt32(kVK_LeftArrow)
        case .wider: return UInt32(kVK_RightArrow)
        case .nearer: return UInt32(kVK_DownArrow)
        case .farther: return UInt32(kVK_UpArrow)
        case .resetPanel: return UInt32(kVK_ANSI_0)
        case .flatter: return UInt32(kVK_ANSI_LeftBracket)
        case .curvier: return UInt32(kVK_ANSI_RightBracket)
        case .cycleMode: return UInt32(kVK_ANSI_M)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .emergencyQuit: return UInt32(optionKey | cmdKey)
        default: return Self.ctrlOptCmd
        }
    }

    var label: String {
        switch self {
        case .emergencyQuit: return "⌥⌘Q"
        case .narrower: return "⌃⌥⌘←"
        case .wider: return "⌃⌥⌘→"
        case .nearer: return "⌃⌥⌘↓"
        case .farther: return "⌃⌥⌘↑"
        case .resetPanel: return "⌃⌥⌘0"
        case .flatter: return "⌃⌥⌘["
        case .curvier: return "⌃⌥⌘]"
        case .cycleMode: return "⌃⌥⌘M"
        }
    }
}

// Panel preferences, persisted in UserDefaults
struct DesktopSettings {
    static let widthRange: ClosedRange<Float> = 40...140
    static let distanceRange: ClosedRange<Float> = 0.75...3
    static let defaultWidthDeg: Float = 90
    static let defaultDistanceM: Float = 1.5
    static let defaultCurvature: Float = 0.5

    // Angular width of the panel; the height follows the display's aspect
    var widthDeg: Float {
        didSet { widthDeg = min(max(widthDeg, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
    }
    // Distance to the panel's center; the angular size stays the same, so
    // text doesn't change size when the panel moves
    var distanceM: Float {
        didSet { distanceM = min(max(distanceM, Self.distanceRange.lowerBound), Self.distanceRange.upperBound) }
    }
    // 0: flat, 1: an arc centered on the head (every column at the same
    // distance); in between the edges bend toward the viewer
    var curvature: Float {
        didSet { curvature = min(max(curvature, 0), 1) }
    }
    var modeIndex: Int {
        didSet { modeIndex = (modeIndex % DeskMode.all.count + DeskMode.all.count) % DeskMode.all.count }
    }

    static func load() -> DesktopSettings {
        let d = UserDefaults.standard
        return DesktopSettings(
            widthDeg: d.object(forKey: "desk.widthDeg") as? Float ?? defaultWidthDeg,
            distanceM: d.object(forKey: "desk.distanceM") as? Float ?? defaultDistanceM,
            curvature: d.object(forKey: "desk.curvature") as? Float ?? defaultCurvature,
            modeIndex: d.object(forKey: "desk.modeIndex") as? Int ?? DeskMode.defaultIndex)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(widthDeg, forKey: "desk.widthDeg")
        d.set(distanceM, forKey: "desk.distanceM")
        d.set(curvature, forKey: "desk.curvature")
        d.set(modeIndex, forKey: "desk.modeIndex")
    }

    var mode: DeskMode { DeskMode.all[modeIndex] }
}

// The captured display and the cursor on it, as of the last cursor-guard tick
struct DisplaySnapshot {
    var cursor: CGPoint // global CG coordinates
    var bounds: CGRect
    var pixelSize: (width: Int, height: Int)

    static func read(_ id: CGDirectDisplayID) -> DisplaySnapshot {
        let b = CGDisplayBounds(id)
        return DisplaySnapshot(cursor: CGEvent(source: nil)?.location ?? CGPoint(x: b.midX, y: b.midY),
                               bounds: b, pixelSize: ScreenCapture.pixelSize(of: id))
    }
}

final class DesktopMode {
    let capture: ScreenCapture
    private(set) var settings = DesktopSettings.load()
    // nil: the private API failed, capturing the current main display instead
    private var virtual: VirtualDisplay?
    private let arranger = DisplayArranger()
    private let headsetID: CGDirectDisplayID?
    private var sweeper: WindowSweeper?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var cursorGuard: DispatchSourceTimer?
    private let guardQueue = DispatchQueue(label: "desktop.cursor-guard", qos: .userInteractive)
    private let snapshotLock = NSLock()
    private var snapshotValue: DisplaySnapshot
    private var arranged = false
    // System audio outputs before switching them to the headset, for restore
    private var savedAudio: [(selector: AudioObjectPropertySelector, id: AudioDeviceID)] = []

    // Short notices for the headset (OSD toast) and a callback once the
    // layout has changed (the headset window must follow its display)
    var onNotice: ((String, Double) -> Void)?
    var onArranged: (() -> Void)?
    var onRecenter: (() -> Void)?

    // Control bar under the panel (desk_bar.swift)
    let bar: DesktopBar
    private(set) var switchingMode = false

    init(device: MTLDevice, queue: MTLCommandQueue, headsetID: CGDirectDisplayID?) {
        self.headsetID = headsetID
        virtual = VirtualDisplay(mode: DesktopSettings.load().mode)
        capture = ScreenCapture(displayID: virtual?.displayID ?? CGMainDisplayID(), device: device, queue: queue)
        bar = DesktopBar(device: device)
        snapshotValue = DisplaySnapshot.read(capture.displayID)
        bar.desktop = self
    }

    // What the render loop needs from WindowServer each frame, read off the
    // main thread. Asking WindowServer synchronously (cursor position,
    // display bounds and mode) can stall for milliseconds while it composites
    // the big virtual display; on the main thread that made frames late by
    // a varying amount and the panel trembled
    var snapshot: DisplaySnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotValue
    }

    private func storeSnapshot(_ value: DisplaySnapshot) {
        snapshotLock.lock()
        snapshotValue = value
        snapshotLock.unlock()
    }

    // Panel geometry for the shader's panel_hit (Uniforms.p8/p9), meters
    func panelGeometry(aspect: Float, ipdMM: Float) -> (g: SIMD4<Float>, h: SIMD4<Float>) {
        var s = surface(widthDeg: settings.widthDeg, aspect: aspect)
        s.h.x = ipdMM / 2000
        return s
    }

    // A rectangle on the panel's surface (same distance and curvature) that
    // spans widthDeg as seen from the head, whatever the curvature, so
    // bending it doesn't change its apparent size
    func surface(widthDeg: Float, aspect: Float) -> (g: SIMD4<Float>, h: SIMD4<Float>) {
        let r = settings.distanceM
        let halfAngle = widthDeg * .pi / 360
        let k = settings.curvature
        let halfIPD: Float = 0
        if k < 0.01 {
            let halfW = r * tanf(halfAngle)
            return (SIMD4(r, 0, halfW, halfW / aspect), SIMD4(halfIPD, 0, 2 * halfW, 0))
        }
        // Cylinder of radius r/k with its front at distance r: find the arc
        // half-angle whose edge is seen from the head at halfAngle (monotonic,
        // so a bisection is enough)
        let rc = r / k
        func seenAngle(_ phi: Float) -> Float {
            atan2f(rc * sinf(phi), r - rc + rc * cosf(phi))
        }
        var lo: Float = 0
        var hi: Float = .pi
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if seenAngle(mid) < halfAngle { lo = mid } else { hi = mid }
        }
        let phiMax = (lo + hi) / 2
        let width = 2 * rc * phiMax // arc length
        return (SIMD4(r, rc, phiMax, width / aspect / 2), SIMD4(halfIPD, 0, width, 0))
    }

    func start() {
        registerHotKeys()
        routeSystemAudio()
        guard let virtual else {
            print("[desktop] virtual display unavailable — capturing main display")
            onNotice?("Virtual display unavailable — showing the main display", 6)
            startCapture()
            return
        }
        print("[desktop] mode on — virtual display \(virtual.displayID), \(settings.mode.label)")
        arranger.saveOriginal(excluding: virtual.displayID)
        waitForModes(attempt: 0)
    }

    // The new display's modes show up in CoreGraphics a moment after creation
    private func waitForModes(attempt: Int) {
        guard let virtual else { return }
        let ready = virtual.cgMode(for: settings.mode) != nil
        if ready || attempt >= 30 {
            // Never leave the virtual display as a side screen: without the
            // arrangement the apps stay on the built-in display, out of sight
            if !ready {
                print("[desktop] !!! \(settings.mode.label) never appeared — arranging anyway")
                virtual.logAvailableModes()
            }
            arranger.arrange(virtual: virtual, mode: settings.mode) { [weak self] in
                guard let self else { return }
                self.arranged = true
                self.onArranged?()
                if self.arranger.builtInPolicy == .guarded {
                    self.onNotice?("Built-in display could not mirror — kept out of reach instead", 5)
                }
                self.startCapture()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForModes(attempt: attempt + 1)
            }
        }
    }

    private func startCapture() {
        startCursorGuard()
        startSweeper()
        capture.start()
    }

    func stop() {
        cursorGuard?.cancel()
        cursorGuard = nil
        sweeper?.stop()
        sweeper = nil
        capture.stop()
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = []
        if let handler = hotKeyHandler {
            RemoveEventHandler(handler)
            hotKeyHandler = nil
        }
        restoreSystemAudio()
        // Un-mirror and restore the layout while the virtual display still
        // exists, then let it go
        if virtual != nil {
            if arranged {
                arranger.restore()
            }
            virtual = nil
            print("[displays] virtual display released")
        }
    }

    private func handle(_ key: DesktopHotKey) {
        switch key {
        case .emergencyQuit:
            print("[desktop] emergency quit (\(key.label))")
            // Display restore lives in applicationWillTerminate
            NSApp.terminate(nil)
            return
        case .narrower: adjust { $0.widthDeg -= 5 }
        case .wider: adjust { $0.widthDeg += 5 }
        case .nearer: adjust { $0.distanceM -= 0.25 }
        case .farther: adjust { $0.distanceM += 0.25 }
        case .flatter: adjust { $0.curvature -= 0.25 }
        case .curvier: adjust { $0.curvature += 0.25 }
        case .resetPanel: resetPanel()
        case .cycleMode: stepMode(by: 1)
        }
    }

    // Panel size/distance/curve change (hotkeys and the control bar)
    func adjust(_ change: (inout DesktopSettings) -> Void) {
        change(&settings)
        settings.save()
        bar.redrawSoon()
        print(String(format: "[desktop] panel %.0f° · %.2f m · curve %.2f",
                     settings.widthDeg, settings.distanceM, settings.curvature))
    }

    func resetPanel() {
        adjust {
            $0.widthDeg = DesktopSettings.defaultWidthDeg
            $0.distanceM = DesktopSettings.defaultDistanceM
            $0.curvature = DesktopSettings.defaultCurvature
        }
    }

    // Next/previous mode in the table; one switch at a time
    func stepMode(by step: Int) {
        guard let virtual, arranged else {
            onNotice?("Display modes need the virtual display", 2)
            return
        }
        guard !switchingMode else { return }
        switchingMode = true
        settings.modeIndex += step
        settings.save()
        bar.redrawSoon()
        let mode = settings.mode
        print("[desktop] switching to \(mode.label)")
        arranger.setMode(mode, on: virtual) { [weak self] ok in
            guard let self else { return }
            self.switchingMode = false
            self.capture.updateSize()
            self.onArranged?()
            self.bar.redrawSoon()
            if !ok {
                self.onNotice?("Display mode \(mode.label) failed (see log)", 3)
            }
        }
    }

    // MARK: Audio

    // Everything the user hears should come from the headset: make it the
    // system output (and the alert/UI-sound output) for all apps
    private func routeSystemAudio() {
        guard let headset = HeadsetAudio.findOutputDevice() else {
            print("[audio] no PS VR2 audio output — system output unchanged")
            return
        }
        for selector in [HeadsetAudio.defaultOutput, HeadsetAudio.systemOutput] {
            guard let current = HeadsetAudio.defaultDevice(selector), current != headset.id else { continue }
            if HeadsetAudio.setDefaultDevice(selector, headset.id) {
                savedAudio.append((selector, current))
            } else {
                print("[audio] !!! could not switch the system output to \(headset.name)")
            }
        }
        print("[audio] system output → \(headset.name)"
            + (savedAudio.isEmpty ? " (already)" : ", was \(HeadsetAudio.name(of: savedAudio[0].id))"))
    }

    // Back to what was selected before, if that device is still there
    private func restoreSystemAudio() {
        for (selector, id) in savedAudio {
            HeadsetAudio.setDefaultDevice(selector, id)
        }
        if let first = savedAudio.first {
            print("[audio] system output restored → \(HeadsetAudio.name(of: first.id))")
        }
        savedAudio = []
    }

    // MARK: Cursor guard

    // The only display the user can see is the captured one: a cursor that
    // drifts onto the headset display (or any other screen) is invisible and
    // its clicks land on the wrong app. Polled at 250 Hz on its own queue
    // (never the main thread, see snapshot) and warped back to the nearest
    // point inside the captured display; each tick also refreshes the
    // snapshot. Coordinates are global CG space (origin top-left of the main
    // display, y down) for both CGDisplayBounds and CGEvent.location
    private func startCursorGuard() {
        guard cursorGuard == nil else { return }
        warpCursorToCenter()
        let timer = DispatchSource.makeTimerSource(queue: guardQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        var tick = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // The mode only changes on a switch: re-read it ~10 times a second
            tick += 1
            let pixelSize = tick % 25 == 0
                ? ScreenCapture.pixelSize(of: self.capture.displayID) : self.snapshot.pixelSize
            self.storeSnapshot(self.guardCursor(pixelSize: pixelSize))
        }
        timer.resume()
        cursorGuard = timer
    }

    func warpCursorToCenter() {
        let b = CGDisplayBounds(capture.displayID)
        warpCursor(to: CGPoint(x: b.midX, y: b.midY))
    }

    // On guardQueue
    private func guardCursor(pixelSize: (width: Int, height: Int)) -> DisplaySnapshot {
        let b = CGDisplayBounds(capture.displayID)
        guard let p = CGEvent(source: nil)?.location else {
            return DisplaySnapshot(cursor: CGPoint(x: b.midX, y: b.midY), bounds: b, pixelSize: pixelSize)
        }
        // maxX/maxY themselves belong to the neighbouring display
        let inside = CGPoint(x: min(max(p.x, b.minX), b.maxX - 1),
                             y: min(max(p.y, b.minY), b.maxY - 1))
        if inside != p {
            warpCursor(to: inside)
        }
        return DisplaySnapshot(cursor: inside, bounds: b, pixelSize: pixelSize)
    }

    private func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // A warp freezes mouse input for ~0.25 s; re-associating cancels that
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Window sweeper

    // Windows that end up on a display the user can't see (headset; the
    // built-in screen when it is guarded instead of mirrored) are moved onto
    // the captured display
    private func startSweeper() {
        guard sweeper == nil, let headsetID else { return }
        let captured = capture.displayID
        let sweeper = WindowSweeper(
            forbiddenFrames: { [weak self] in
                // Called on the sweeper's queue; the arranger lives on main
                let far = DispatchQueue.main.sync { self?.arranger.farDisplays ?? [] }
                return ([headsetID] + far)
                    .filter { $0 != captured }
                    .map { CGDisplayBounds($0) }
            },
            targetFrame: { CGDisplayBounds(captured) })
        sweeper.onStray = { [weak self] name, moved in
            if moved {
                self?.onNotice?("Window \"\(name)\" brought back", 3)
                print("[sweeper] window \"\(name)\" moved onto the desk display")
            } else {
                self?.onNotice?("Window \"\(name)\" is off-screen (see log)", 5)
                print("[sweeper] window \"\(name)\" is on a hidden display. For auto-move, grant access:")
                print("[sweeper] Settings → Privacy & Security → Accessibility → \"+\" → PSVR2Player.app")
            }
        }
        sweeper.start()
        self.sweeper = sweeper
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        // The C callback can't capture context: self travels as userData
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let mode = Unmanaged<DesktopMode>.fromOpaque(userData).takeUnretainedValue()
            guard let key = DesktopHotKey(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            mode.handle(key)
            return noErr
        }, 1, &spec, userData, &hotKeyHandler)

        var failed: [String] = []
        for key in DesktopHotKey.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5056_5232), id: key.rawValue) // 'PVR2'
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                failed.append("\(key.label) (\(status))")
            }
        }
        print("[desktop] hotkeys registered: \(hotKeyRefs.count)/\(DesktopHotKey.allCases.count)"
            + (failed.isEmpty ? "" : " — !!! failed: \(failed.joined(separator: ", "))"))
    }
}
