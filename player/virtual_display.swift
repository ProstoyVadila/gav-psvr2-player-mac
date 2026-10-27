import AppKit

// Desktop mode's display: a virtual "PSVR2 Desk" display made the main one,
// with the built-in screen mirroring it and the headset display pushed out
// of reach. The only file that touches the private CGVirtualDisplay API
// (declared in cgvirtualdisplay.h).
//
// CoreGraphics display configuration in short: CGBeginDisplayConfiguration
// opens a transaction, CGConfigureDisplay* calls stage changes (origin,
// mirroring, mode), CGCompleteDisplayConfiguration applies them all at once.
// The main display is by definition the one at origin (0, 0). Applying with
// .forAppOnly makes WindowServer undo the changes when the process exits,
// even after a crash — the safety net for "never leave the user blind".

// The virtual display's modes. All HiDPI: backing pixels are 2× the logical
// size, so text is rendered at Retina sharpness and the panel is sampled
// from a big texture. Changing the mode is how text size is controlled
struct DeskMode: Equatable {
    let name: String
    let width: Int  // logical ("looks like") points
    let height: Int
    var pixelWidth: Int { width * 2 }
    var pixelHeight: Int { height * 2 }
    var label: String { "\(name) \(width)×\(height)" }

    static let all = [
        DeskMode(name: "Wide", width: 1920, height: 1080),
        DeskMode(name: "Wide", width: 2560, height: 1440),
        DeskMode(name: "Ultrawide", width: 2560, height: 1080),
        DeskMode(name: "Ultrawide", width: 3440, height: 1440),
        DeskMode(name: "Super-ultrawide", width: 3840, height: 1080),
    ]
    static let defaultIndex = 2 // Ultrawide 2560×1080
}

// Owns the private CGVirtualDisplay object: the display exists exactly as
// long as this object is alive
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    // nil when the private API is unavailable or refuses (logged)
    init?(mode: DeskMode) {
        // The class lives in CoreGraphics at runtime; check before touching it
        guard NSClassFromString("CGVirtualDisplay") != nil else {
            print("[displays] !!! CGVirtualDisplay class not found")
            return nil
        }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "PSVR2 Desk"
        // Must cover the largest backing size in the mode list
        descriptor.maxPixelsWide = UInt32(DeskMode.all.map(\.pixelWidth).max()!)
        descriptor.maxPixelsHigh = UInt32(DeskMode.all.map(\.pixelHeight).max()!)
        // Physical size only feeds the reported DPI; ~a 34" ultrawide
        descriptor.sizeInMillimeters = CGSize(width: 800, height: 340)
        descriptor.vendorID = 0x5056 // arbitrary but stable, so macOS
        descriptor.productID = 0x5232 // remembers the display's settings
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in
            print("[displays] virtual display terminated")
        }
        display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else {
            print("[displays] !!! CGVirtualDisplay creation failed")
            return nil
        }

        guard setMode(mode) else {
            print("[displays] !!! CGVirtualDisplay rejected the mode list")
            return nil
        }
        print("[displays] virtual display \"PSVR2 Desk\" created, id \(display.displayID)")
    }

    // The display offers exactly one size, so that is the mode it runs in;
    // switching = applying settings again, which lands in ~0.1 s. Measured
    // (macOS 26): with hiDPI = 1 a listed size is the logical one and runs
    // at 2× backing pixels — [2560×1080] gives 2560x1080 (5120x2160 px).
    // Listing backing sizes instead gave no HiDPI mode at all, and with the
    // whole table listed macOS picked the largest size and
    // CGConfigureDisplayWithDisplayMode never moved it off that
    func setMode(_ mode: DeskMode) -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(mode.width), height: UInt(mode.height), refreshRate: 60)
        ]
        return display.apply(settings)
    }

    // The CoreGraphics mode for one of our modes, or nil if the system
    // doesn't list it (yet: modes appear shortly after creation)
    func cgMode(for mode: DeskMode) -> CGDisplayMode? {
        // Without this option the HiDPI and 1× variants of a size are folded together
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
        return modes.first {
            $0.width == mode.width && $0.height == mode.height
                && $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight
        }
    }

    func logAvailableModes() {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
        let list = modes.map { "\($0.width)x\($0.height)(\($0.pixelWidth)x\($0.pixelHeight))" }
        print("[displays] virtual display modes: \(list.joined(separator: " "))")
    }
}

// How the built-in screen is kept out of reach
enum BuiltInPolicy: String {
    case mirror // mirrors the virtual display: no separate space at all
    case guarded // stays extended, far away; cursor guard and sweeper watch it
}

// Saves, rearranges and restores the display layout around the virtual display
final class DisplayArranger {
    // A display's place in the layout, as saved before changing anything
    private struct SavedDisplay: Codable {
        let id: CGDirectDisplayID
        let x: Int32
        let y: Int32
        let mirrorOf: CGDirectDisplayID
        let modeID: Int32 // CGDisplayMode.ioDisplayModeID, 0 if unknown
    }
    private static let savedKey = "desk.savedConfig"
    static let dirtyKey = "desk.dirty"

    private(set) var builtInPolicy = BuiltInPolicy.mirror
    // Pushed out of reach (headset; plus the built-in screen when guarded)
    private(set) var farDisplays: [CGDirectDisplayID] = []

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // The original layout goes to UserDefaults before anything changes, with
    // a dirty flag that a clean restore clears (crash recovery reads it, M3)
    func saveOriginal(excluding virtualID: CGDirectDisplayID) {
        let displays = Self.onlineDisplays().filter { $0 != virtualID }.map { id -> SavedDisplay in
            let b = CGDisplayBounds(id)
            return SavedDisplay(id: id, x: Int32(b.minX), y: Int32(b.minY),
                                mirrorOf: CGDisplayMirrorsDisplay(id),
                                modeID: CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? 0)
        }
        if let data = try? JSONEncoder().encode(displays) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
            UserDefaults.standard.set(true, forKey: Self.dirtyKey)
        }
        for d in displays {
            print("[displays] saved: display \(d.id) at (\(d.x), \(d.y))"
                + (d.mirrorOf != 0 ? " mirroring \(d.mirrorOf)" : ""))
        }
    }

    // Make the virtual display main in the given mode, mirror the built-in
    // screen to it (or guard it) and push the headset away. Asynchronous:
    // WindowServer applies a configuration a moment after
    // CGCompleteDisplayConfiguration returns, and a mode read back (or a new
    // transaction started) before that sees the old state. So the layout
    // goes first, then the mode in its own step, verified by polling
    func arrange(virtual: VirtualDisplay, mode: DeskMode, completion: @escaping () -> Void) {
        let virtualID = virtual.displayID
        let builtIn = Self.onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 && $0 != virtualID }
        let others = Self.onlineDisplays().filter { $0 != virtualID && $0 != builtIn }

        builtInPolicy = builtIn != nil ? .mirror : .guarded
        farDisplays = others
        apply("arrange") { config in
            CGConfigureDisplayOrigin(config, virtualID, 0, 0)
            if let builtIn {
                CGConfigureDisplayMirrorOfDisplay(config, builtIn, virtualID)
            }
            self.pushAway(others, config: config, virtualMode: mode)
        }

        // Mirroring tends to force a mode common to the whole mirror set.
        // If the wide mode doesn't stick, give up mirroring
        setMode(mode, on: virtual) { [weak self] ok in
            guard let self else { return }
            if ok || builtIn == nil {
                self.finishArrange(virtualID: virtualID, mode: mode, builtIn: builtIn)
                completion()
                return
            }
            print("[displays] !!! mirroring keeps the wrong mode — switching the built-in display to guard")
            self.builtInPolicy = .guarded
            self.farDisplays = others + [builtIn!]
            self.apply("guard built-in") { config in
                CGConfigureDisplayMirrorOfDisplay(config, builtIn!, kCGNullDirectDisplay)
                CGConfigureDisplayOrigin(config, virtualID, 0, 0)
                self.pushAway(self.farDisplays, config: config, virtualMode: mode)
            }
            self.setMode(mode, on: virtual) { _ in
                self.finishArrange(virtualID: virtualID, mode: mode, builtIn: builtIn)
                completion()
            }
        }
    }

    private func finishArrange(virtualID: CGDirectDisplayID, mode: DeskMode, builtIn: CGDirectDisplayID?) {
        print("[displays] built-in: \(builtIn == nil ? "none" : builtInPolicy.rawValue)")
        print("[displays] virtual mode: \(describeMode(of: virtualID))"
            + (modeIsActive(mode, on: virtualID) ? "" : " (!!! requested \(mode.label))"))
        for id in Self.onlineDisplays() {
            print("[displays] display \(id): bounds \(CGDisplayBounds(id))"
                + (CGDisplayIsMain(id) != 0 ? " MAIN" : "")
                + (CGDisplayMirrorsDisplay(id) != 0 ? " mirrors \(CGDisplayMirrorsDisplay(id))" : ""))
        }
    }

    // Set the virtual display's mode and wait (up to ~1.5 s per attempt) for
    // it to show up; up to 3 attempts. Also used for mode switches while
    // running (text size); the arrangement stays
    func setMode(_ mode: DeskMode, on virtual: VirtualDisplay, attempt: Int = 1,
                 completion: @escaping (Bool) -> Void) {
        let id = virtual.displayID
        if modeIsActive(mode, on: id) {
            completion(true)
            return
        }
        // Give the previous transaction a moment to land before the next one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if !virtual.setMode(mode) {
                print("[displays] !!! CGVirtualDisplay rejected \(mode.label) (attempt \(attempt))")
            }
            self.poll(until: { self.modeIsActive(mode, on: id) }, timeout: 1.5) { ok in
                if ok {
                    print("[displays] mode → \(self.describeMode(of: id)) (attempt \(attempt))")
                    // A size change moves the neighbours: keep the others away
                    self.apply("keep displays away") { config in
                        self.pushAway(self.farDisplays, config: config, virtualMode: mode)
                    }
                    completion(true)
                } else if attempt < 3 {
                    print("[displays] mode is still \(self.describeMode(of: id)) — retrying \(mode.label)")
                    self.setMode(mode, on: virtual, attempt: attempt + 1, completion: completion)
                } else {
                    print("[displays] !!! mode stays \(self.describeMode(of: id)), wanted \(mode.label)")
                    completion(false)
                }
            }
        }
    }

    private func poll(until condition: @escaping () -> Bool, timeout: Double,
                      started: Double = CACurrentMediaTime(), done: @escaping (Bool) -> Void) {
        if condition() {
            done(true)
        } else if CACurrentMediaTime() - started > timeout {
            done(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.poll(until: condition, timeout: timeout, started: started, done: done)
            }
        }
    }

    // Undo everything: un-mirror, original origins and modes. Runs before the
    // virtual display is released, so nothing falls back onto it
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode([SavedDisplay].self, from: data) else {
            UserDefaults.standard.set(false, forKey: Self.dirtyKey)
            return
        }
        let online = Set(Self.onlineDisplays())
        apply("restore") { config in
            for d in saved where online.contains(d.id) {
                CGConfigureDisplayMirrorOfDisplay(
                    config, d.id, online.contains(d.mirrorOf) ? d.mirrorOf : kCGNullDirectDisplay)
                CGConfigureDisplayOrigin(config, d.id, d.x, d.y)
                let modes = CGDisplayCopyAllDisplayModes(d.id, nil) as? [CGDisplayMode] ?? []
                if let mode = modes.first(where: { $0.ioDisplayModeID == d.modeID }) {
                    CGConfigureDisplayWithDisplayMode(config, d.id, mode, nil)
                }
            }
        }
        UserDefaults.standard.set(false, forKey: Self.dirtyKey)
        print("[displays] original arrangement restored")
    }

    // Far beyond the virtual display's bottom-right corner, so no display
    // shares an edge with it. WindowServer may snap displays back into
    // contact; the cursor guard covers that case. Each display gets its own
    // spot so they don't overlap each other
    private func pushAway(_ ids: [CGDirectDisplayID], config: CGDisplayConfigRef?, virtualMode: DeskMode) {
        for (i, id) in ids.enumerated() {
            let x = Int32(virtualMode.width + 4000 + i * 6000)
            CGConfigureDisplayOrigin(config, id, x, Int32(virtualMode.height + 4000))
        }
    }

    private func apply(_ what: String, _ stage: (CGDisplayConfigRef?) -> Void) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            print("[displays] !!! \(what): CGBeginDisplayConfiguration failed")
            return
        }
        stage(config)
        let err = CGCompleteDisplayConfiguration(config, .forAppOnly)
        if err != .success {
            print("[displays] !!! \(what): CGCompleteDisplayConfiguration error \(err.rawValue)")
        }
    }

    private func modeIsActive(_ mode: DeskMode, on id: CGDirectDisplayID) -> Bool {
        guard let m = CGDisplayCopyDisplayMode(id) else { return false }
        return m.width == mode.width && m.height == mode.height && m.pixelWidth == mode.pixelWidth
    }

    private func describeMode(of id: CGDirectDisplayID) -> String {
        guard let m = CGDisplayCopyDisplayMode(id) else { return "?" }
        return "\(m.width)x\(m.height) (\(m.pixelWidth)x\(m.pixelHeight) px)"
    }
}
