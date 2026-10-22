// Watchdog for windows on the headset display: other apps' windows and dialogs
// that open there are invisible to the user — every 2 s the sweeper finds them
// and moves them to the monitor (requires the Accessibility permission), or
// warns with an OSD plate. Desktop mode passes several forbidden displays and
// the virtual display as the target; the frames are re-read on every sweep
// because the display arrangement can change while running.

import AppKit
import ApplicationServices

final class WindowSweeper {
    // CG coordinates: y down from the top of the main screen
    private let forbiddenFrames: () -> [CGRect] // displays the user can't see
    private let targetFrame: () -> CGRect       // where to move windows
    private var timer: Timer?
    // Avoid spamming plates every 2 s about the same window
    private var reported: [String: Double] = [:]
    // app name, whether the move succeeded
    var onStray: ((String, Bool) -> Void)?

    init(forbiddenFrames: @escaping () -> [CGRect], targetFrame: @escaping () -> CGRect) {
        self.forbiddenFrames = forbiddenFrames
        self.targetFrame = targetFrame
    }

    convenience init(vrFrame: CGRect, targetFrame: CGRect) {
        self.init(forbiddenFrames: { [vrFrame] }, targetFrame: { targetFrame })
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sweep() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let forbidden = forbiddenFrames()
        let target = targetFrame()

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  // Regular windows and dialogs; the menu bar, Dock and overlays are higher
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer <= 8,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                              width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard rect.width > 60, rect.height > 40,
                  forbidden.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) })
            else { continue }

            let name = (info[kCGWindowOwnerName as String] as? String) ?? "?"
            let moved = AXIsProcessTrusted() ? move(pid: pid, rect: rect, to: target) : false

            let key = "\(pid)-\(Int(rect.minX))-\(Int(rect.minY))"
            let now = CACurrentMediaTime()
            if moved || (reported[key] ?? -1e9) + 30 < now {
                reported[key] = now
                onStray?(name, moved)
            }
        }
    }

    // Find the process's AX window by matching position and move it to the monitor
    private func move(pid: pid_t, rect: CGRect, to targetFrame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            == .success, let windows = value as? [AXUIElement] else { return false }

        for win in windows {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
                == .success, let posRef else { continue }
            var pos = CGPoint.zero
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                  abs(pos.x - rect.minX) < 3, abs(pos.y - rect.minY) < 3 else { continue }

            var target = CGPoint(
                x: min(max(targetFrame.minX, targetFrame.midX - rect.width / 2),
                       targetFrame.maxX - rect.width),
                y: min(max(targetFrame.minY + 40, targetFrame.midY - rect.height / 2),
                       targetFrame.maxY - rect.height))
            guard let tv = AXValueCreate(.cgPoint, &target) else { continue }
            if AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, tv)
                == .success {
                return true
            }
        }
        return false
    }
}
