import AppKit
import Metal

// Desktop mode's control bar: a strip of buttons on the same curved surface
// as the panel, just below it (panel size, distance, curve, display mode,
// recenter, quit), so nothing needs a hotkey while the headset is on.
//
// Reaching it: move the mouse to the bottom edge of the desk display and
// hold it there for a moment. The real cursor stays on that edge and keeps
// moving sideways, so the bar's pointer simply follows its x; moving back up
// leaves the bar. (A downward push detected from CGGetLastMouseDelta was
// tried first and never triggered in the headset.) While the bar
// is active a transparent strip window covers the bottom edge (above the
// Dock) and swallows the clicks, so they never reach the app underneath.
// The panel doesn't activate the app, so keyboard focus stays where it was.

final class DesktopBar {
    static let texW = 2400 // fits the row of buttons (see buildLayout)
    static let texH = 200
    static let widthDeg: Float = 80 // angular width, whatever the panel size
    static let dwell = 0.2 // seconds on the bottom edge before the bar takes over

    private(set) var texture: MTLTexture
    // Cursor on the bar: real cursor pushed into the bottom edge
    private(set) var active = false

    weak var desktop: DesktopMode?

    private enum Action {
        case widthDown, widthUp, distDown, distUp, curveDown, curveUp
        case modePrev, modeNext, recenter, reset, quit
    }

    // A cell in the single row; value cells have no action
    private struct Cell {
        let rect: CGRect // CG texture coordinates (origin bottom-left)
        let label: () -> String
        let action: Action?
    }

    private var cells: [Cell] = []
    private var captions: [(text: String, rect: CGRect)] = []
    private var cursorU = 0.5
    private var hovered = -1
    private var dirty = true
    private var lastRedraw = 0.0

    // When the cursor reached the bottom edge (0: not on it)
    private var edgeSince = 0.0
    private let catcher = ClickCatcher()

    init(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.texW, height: Self.texH, mipmapped: false)
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)!
        catcher.onClick = { [weak self] in self?.click() }
        buildLayout()
    }

    // MARK: Layout

    private func buildLayout() {
        let small = 76.0, value = 150.0, wide = 260.0
        let cellY = 30.0, cellH = 96.0 // bottom margin ≈ the caption's top margin
        let gap = 10.0, groupGap = 44.0
        typealias Spec = (width: Double, label: () -> String, action: Action?)
        let s = { [weak self] () -> DesktopSettings? in self?.desktop?.settings }
        let groups: [(String, [Spec])] = [
            ("Size", [
                (small, { "−" }, .widthDown),
                (value, { s().map { String(format: "%.0f°", $0.widthDeg) } ?? "" }, nil),
                (small, { "+" }, .widthUp)]),
            ("Distance", [
                (small, { "−" }, .distDown),
                (value, { s().map { String(format: "%.2f m", $0.distanceM) } ?? "" }, nil),
                (small, { "+" }, .distUp)]),
            ("Curve", [
                (small, { "−" }, .curveDown),
                (value, { s().map { String(format: "%.0f%%", $0.curvature * 100) } ?? "" }, nil),
                (small, { "+" }, .curveUp)]),
            ("Resolution", [
                (small, { "◀" }, .modePrev),
                (wide + 60, { [weak self] in self?.modeLabel() ?? "" }, nil),
                (small, { "▶" }, .modeNext)]),
            ("View", [
                (190, { "Recenter" }, .recenter),
                (150, { "Reset" }, .reset)]),
            ("", [
                (130, { "Quit" }, .quit)]),
        ]

        let total = groups.reduce(0.0) { sum, g in
            sum + g.1.reduce(0.0) { $0 + $1.width } + gap * Double(g.1.count - 1)
        } + groupGap * Double(groups.count - 1)
        var x = (Double(Self.texW) - total) / 2
        cells = []
        captions = []
        for (caption, specs) in groups {
            let x0 = x
            for spec in specs {
                cells.append(Cell(rect: CGRect(x: x, y: cellY, width: spec.width, height: cellH),
                                  label: spec.label, action: spec.action))
                x += spec.width + gap
            }
            x -= gap
            captions.append((caption, CGRect(x: x0, y: cellY + cellH + 6, width: x - x0, height: 46)))
            x += groupGap
        }
    }

    private func modeLabel() -> String {
        guard let d = desktop else { return "" }
        let m = d.settings.mode
        return d.switchingMode ? "\(m.width)×\(m.height)…" : "\(m.width)×\(m.height)"
    }

    // Surface parameters for the shader (Uniforms.p10): half width (radians
    // on the cylinder / meters flat), half height and vertical center
    // (meters), placed under the panel with a small gap
    func geometry(panel: (g: SIMD4<Float>, h: SIMD4<Float>)) -> SIMD4<Float> {
        guard let d = desktop else { return .zero }
        let bar = d.surface(widthDeg: Self.widthDeg, aspect: Float(Self.texW) / Float(Self.texH))
        let gap = 0.025 * d.settings.distanceM
        let centerY = panel.h.y - panel.g.w - gap - bar.g.w
        return SIMD4(bar.g.z, bar.g.w, centerY, 0)
    }

    // MARK: Input

    // Called every frame from the render loop
    func tick() {
        guard let d = desktop else { return }
        // Cached by the cursor guard: no WindowServer calls on the render loop
        let snap = d.snapshot
        let p = snap.cursor
        let b = snap.bounds
        let atBottom = p.y >= b.maxY - 1.5 && p.x >= b.minX && p.x < b.maxX

        let now = CACurrentMediaTime()
        if !active {
            if !atBottom {
                edgeSince = 0
            } else if edgeSince == 0 {
                edgeSince = now
            } else if now - edgeSince > Self.dwell {
                enter(bounds: b)
            }
        } else if p.y < b.maxY - 10 || p.x < b.minX || p.x >= b.maxX {
            leave()
        }

        if active {
            let u = min(max((p.x - b.minX) / b.width, 0), 1)
            if u != cursorU {
                cursorU = u
                dirty = true
            }
            let h = hitIndex()
            if h != hovered {
                hovered = h
                dirty = true
            }
        }

        // Pointer moves are throttled to 60 Hz; state changes redraw at once
        if dirty && now - lastRedraw > 1.0 / 60 {
            redraw()
        }
    }

    private func enter(bounds b: CGRect) {
        active = true
        edgeSince = 0
        dirty = true
        // The strip sits on the desk display's bottom edge; Cocoa's y runs up
        // from the bottom of the main (desk) display
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        catcher.setFrame(NSRect(x: b.minX, y: mainH - b.maxY, width: b.width, height: 14), display: false)
        catcher.orderFrontRegardless()
        print("[desktop] control bar on")
    }

    private func leave() {
        active = false
        hovered = -1
        dirty = true
        catcher.orderOut(nil)
    }

    private func hitIndex() -> Int {
        let x = cursorU * Double(Self.texW)
        return cells.firstIndex { $0.action != nil && x >= $0.rect.minX - 5 && x <= $0.rect.maxX + 5 } ?? -1
    }

    private func click() {
        guard active, hovered >= 0, let action = cells[hovered].action, let d = desktop else { return }
        switch action {
        case .widthDown: d.adjust { $0.widthDeg -= 5 }
        case .widthUp: d.adjust { $0.widthDeg += 5 }
        case .distDown: d.adjust { $0.distanceM -= 0.25 }
        case .distUp: d.adjust { $0.distanceM += 0.25 }
        case .curveDown: d.adjust { $0.curvature -= 0.25 }
        case .curveUp: d.adjust { $0.curvature += 0.25 }
        case .modePrev: d.stepMode(by: -1)
        case .modeNext: d.stepMode(by: 1)
        case .recenter: d.onRecenter?()
        case .reset: d.resetPanel()
        case .quit:
            print("[desktop] quit (control bar)")
            NSApp.terminate(nil)
        }
        redrawSoon()
    }

    func redrawSoon() {
        dirty = true
    }

    // MARK: Drawing

    private lazy var drawContext: CGContext? = CGContext(
        data: nil, width: Self.texW, height: Self.texH,
        bitsPerComponent: 8, bytesPerRow: Self.texW * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
    private lazy var graphicsContext: NSGraphicsContext? =
        drawContext.map { NSGraphicsContext(cgContext: $0, flipped: false) }

    private func redraw() {
        dirty = false
        lastRedraw = CACurrentMediaTime()
        guard let ctx = drawContext, let gc = graphicsContext else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: Self.texW, height: Self.texH))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc

        let bg = CGRect(x: 4, y: 4, width: Self.texW - 8, height: Self.texH - 8)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        ctx.fillPath()

        for (i, c) in cells.enumerated() {
            if c.action != nil {
                ctx.addPath(CGPath(roundedRect: c.rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
                ctx.setFillColor(i == hovered
                    ? CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1)
                    : CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1))
                ctx.fillPath()
            }
            drawText(c.label(), in: c.rect, size: c.action != nil ? 44 : 40,
                     color: c.action != nil ? .white : NSColor(white: 0.85, alpha: 1))
        }
        for caption in captions where !caption.text.isEmpty {
            drawText(caption.text, in: caption.rect, size: 28, color: NSColor(white: 0.6, alpha: 1))
        }

        if active {
            // Pointer: a white notch on the top edge above the cursor's x
            let x = cursorU * Double(Self.texW)
            let top = Double(Self.texH) - 6
            ctx.move(to: CGPoint(x: x - 16, y: top))
            ctx.addLine(to: CGPoint(x: x + 16, y: top))
            ctx.addLine(to: CGPoint(x: x, y: top - 22))
            ctx.closePath()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
        } else {
            // Dimmed while the cursor is on the desktop
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fill(CGRect(x: 0, y: 0, width: Self.texW, height: Self.texH))
            ctx.setBlendMode(.normal)
        }

        NSGraphicsContext.restoreGraphicsState()
        if let data = ctx.data {
            texture.replace(region: MTLRegionMake2D(0, 0, Self.texW, Self.texH), mipmapLevel: 0,
                            withBytes: data, bytesPerRow: Self.texW * 4)
        }
    }

    private func drawText(_ s: String, in rect: CGRect, size: CGFloat, color: NSColor) {
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
        ])
        let sz = str.size()
        str.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }
}

// Transparent, non-activating strip over the bottom edge that takes the
// clicks meant for the bar. Nearly (not fully) transparent: WindowServer
// passes clicks through pixels with zero alpha
private final class ClickCatcher: NSPanel {
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .screenSaver // above the Dock and the menu bar
        isOpaque = false
        backgroundColor = NSColor(white: 0, alpha: 0.01)
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = CatcherView()
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CatcherView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
