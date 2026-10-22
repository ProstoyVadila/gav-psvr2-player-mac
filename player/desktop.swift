import AppKit
import Carbon.HIToolbox

// Desktop mode (`--desktop`, launched by player/desk): a macOS display shown
// as a panel floating in the headset instead of a video. This file holds the
// mode's coordinator; capture is in screen_capture.swift.

// Global hotkeys, kept in one place so they are easy to change. Carbon's
// RegisterEventHotKey works while another app has keyboard focus and, unlike
// a CGEventTap, needs no Accessibility permission
enum DesktopHotKey: UInt32, CaseIterable {
    case emergencyQuit = 1

    var keyCode: UInt32 {
        switch self {
        case .emergencyQuit: return UInt32(kVK_ANSI_Q)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .emergencyQuit: return UInt32(optionKey | cmdKey)
        }
    }

    var label: String {
        switch self {
        case .emergencyQuit: return "⌥⌘Q"
        }
    }
}

final class DesktopMode {
    let capture: ScreenCapture
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var cursorGuard: Timer?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        // M1: the current main display; M2 replaces it with the virtual one
        let displayID = CGMainDisplayID()
        capture = ScreenCapture(displayID: displayID, device: device, queue: queue)
    }

    func start() {
        print("[desktop] mode on — capturing display \(capture.displayID)")
        registerHotKeys()
        startCursorGuard()
        capture.start()
    }

    func stop() {
        cursorGuard?.invalidate()
        cursorGuard = nil
        capture.stop()
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = []
        if let handler = hotKeyHandler {
            RemoveEventHandler(handler)
            hotKeyHandler = nil
        }
    }

    private func handle(_ key: DesktopHotKey) {
        switch key {
        case .emergencyQuit:
            print("[desktop] emergency quit (\(key.label))")
            // Display restore lives in applicationWillTerminate
            NSApp.terminate(nil)
        }
    }

    // The only display the user can see is the captured one: a cursor that
    // drifts onto the headset display (or any other screen) is invisible and
    // its clicks land on the wrong app. Polled at 250 Hz and warped back to
    // the nearest point inside the captured display. Coordinates are global
    // CG space (origin top-left of the main display, y down) for both
    // CGDisplayBounds and CGEvent.location
    private func startCursorGuard() {
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

        for key in DesktopHotKey.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5056_5232), id: key.rawValue) // 'PVR2'
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                print("[desktop] hotkey \(key.label) registered")
            } else {
                print("[desktop] !!! hotkey \(key.label) not registered (status \(status))")
            }
        }
    }
}
