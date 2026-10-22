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

    // Angular width of the panel; the height follows the display's aspect
    var widthDeg: Float {
        didSet { widthDeg = min(max(widthDeg, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
    }
    // Perceived distance. Until the panel geometry gets real depth (M4) it
    // only sets the stereo disparity; the angular size stays the same, so
    // text doesn't change size when the panel moves
    var distanceM: Float {
        didSet { distanceM = min(max(distanceM, Self.distanceRange.lowerBound), Self.distanceRange.upperBound) }
    }
    var modeIndex: Int {
        didSet { modeIndex = (modeIndex % DeskMode.all.count + DeskMode.all.count) % DeskMode.all.count }
    }

    static func load() -> DesktopSettings {
        let d = UserDefaults.standard
        return DesktopSettings(
            widthDeg: d.object(forKey: "desk.widthDeg") as? Float ?? defaultWidthDeg,
            distanceM: d.object(forKey: "desk.distanceM") as? Float ?? defaultDistanceM,
            modeIndex: d.object(forKey: "desk.modeIndex") as? Int ?? DeskMode.defaultIndex)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(widthDeg, forKey: "desk.widthDeg")
        d.set(distanceM, forKey: "desk.distanceM")
        d.set(modeIndex, forKey: "desk.modeIndex")
    }

    var mode: DeskMode { DeskMode.all[modeIndex] }
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
    private var cursorGuard: Timer?
    private var arranged = false
    // System audio outputs before switching them to the headset, for restore
    private var savedAudio: [(selector: AudioObjectPropertySelector, id: AudioDeviceID)] = []

    // Short notices for the headset (OSD toast) and a callback once the
    // layout has changed (the headset window must follow its display)
    var onNotice: ((String, Double) -> Void)?
    var onArranged: (() -> Void)?

    // Half the typical IPD, for the disparity of a panel at distanceM
    private static let halfIPD: Float = 0.0315

    init(device: MTLDevice, queue: MTLCommandQueue, headsetID: CGDirectDisplayID?) {
        self.headsetID = headsetID
        virtual = VirtualDisplay()
        capture = ScreenCapture(displayID: virtual?.displayID ?? CGMainDisplayID(), device: device, queue: queue)
    }

    // Panel geometry for the renderer: angular width and per-eye disparity in tan units
    var panelWidthDeg: Float { settings.widthDeg }
    var panelDisparity: Float { Self.halfIPD / settings.distanceM }

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
        if virtual.cgMode(for: settings.mode) != nil {
            arranger.arrange(virtual: virtual, mode: settings.mode, headset: headsetID)
            arranged = true
            onArranged?()
            if arranger.builtInPolicy == .guarded {
                onNotice?("Built-in display could not mirror — kept out of reach instead", 5)
            }
            startCapture()
        } else if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForModes(attempt: attempt + 1)
            }
        } else {
            print("[desktop] !!! virtual display modes never appeared — capturing it unarranged")
            virtual.logAvailableModes()
            startCapture()
        }
    }

    private func startCapture() {
        startCursorGuard()
        startSweeper()
        capture.start()
    }

    func stop() {
        cursorGuard?.invalidate()
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
        case .narrower: settings.widthDeg -= 5
        case .wider: settings.widthDeg += 5
        case .nearer: settings.distanceM -= 0.25
        case .farther: settings.distanceM += 0.25
        case .resetPanel:
            settings.widthDeg = DesktopSettings.defaultWidthDeg
            settings.distanceM = DesktopSettings.defaultDistanceM
        case .cycleMode:
            cycleMode()
            return
        }
        settings.save()
        let text = String(format: "Panel %.0f° · %.2f m", settings.widthDeg, settings.distanceM)
        print("[desktop] \(text)")
        onNotice?(text, 1.5)
    }

    // Temporary (M5 replaces it with the settings panel): next mode in the table
    private func cycleMode() {
        guard let virtual, arranged else {
            onNotice?("Display modes need the virtual display", 2)
            return
        }
        settings.modeIndex += 1
        settings.save()
        let mode = settings.mode
        let ok = arranger.setMode(mode, on: virtual)
        capture.updateSize()
        onArranged?()
        onNotice?(ok ? "Display: \(mode.label)" : "Display mode \(mode.label) failed (see log)", 2)
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
    // its clicks land on the wrong app. Polled at 250 Hz and warped back to
    // the nearest point inside the captured display. Coordinates are global
    // CG space (origin top-left of the main display, y down) for both
    // CGDisplayBounds and CGEvent.location
    private func startCursorGuard() {
        guard cursorGuard == nil else { return }
        warpCursorToCenter()
        let timer = Timer(timeInterval: 1.0 / 250, repeats: true) { [weak self] _ in
            self?.guardCursor()
        }
        RunLoop.main.add(timer, forMode: .common) // keeps firing during menu tracking and drags
        cursorGuard = timer
    }

    func warpCursorToCenter() {
        let b = CGDisplayBounds(capture.displayID)
        warpCursor(to: CGPoint(x: b.midX, y: b.midY))
    }

    private func guardCursor() {
        guard let p = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(capture.displayID)
        // maxX/maxY themselves belong to the neighbouring display
        let inside = CGPoint(x: min(max(p.x, b.minX), b.maxX - 1),
                             y: min(max(p.y, b.minY), b.maxY - 1))
        if inside != p {
            warpCursor(to: inside)
        }
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
                ([headsetID] + (self?.arranger.farDisplays ?? []))
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
