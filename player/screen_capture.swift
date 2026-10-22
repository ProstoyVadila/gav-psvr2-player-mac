import AppKit
import CoreMedia
import Metal
import ScreenCaptureKit

// Desktop mode: live capture of one display through ScreenCaptureKit.
//
// SCStream delivers each changed frame as a CMSampleBuffer backed by an
// IOSurface. The surface is wrapped as a Metal texture without a copy
// (CVMetalTextureCache), then blitted into our own mipmapped texture: the
// panel is heavily minified in the headset and samples it trilinearly, like
// the flat-screen video path. Two such textures alternate, so the renderer
// always reads a complete frame while the next one is being written. The
// blit goes on the renderer's command queue: Metal's hazard tracking then
// orders it after any render pass still reading that texture.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "capture.output", qos: .userInteractive)

    // Front: newest complete frame for the renderer. Back: next blit target
    private let lock = NSLock()
    private var front: MTLTexture?
    private var back: MTLTexture?
    private var frameCount = 0

    // Missing Screen Recording permission or another start failure (main thread)
    var onFailure: ((String) -> Void)?

    init(displayID: CGDirectDisplayID, device: MTLDevice, queue: MTLCommandQueue) {
        self.displayID = displayID
        self.device = device
        self.queue = queue
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // Latest complete frame; nil until the first one arrives
    var latestTexture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return front
    }

    // Complete frames since the last call (for the [stat] line)
    func takeFrameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = frameCount
        frameCount = 0
        return n
    }

    // Backing pixel size of the display's current mode (2× the logical size on HiDPI)
    static func pixelSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID))
    }

    func start() {
        // Preflight doesn't prompt; the request shows the system dialog once
        // (it opens on the main display). Without the grant SCShareableContent fails
        if !CGPreflightScreenCaptureAccess() {
            print("[capture] !!! no Screen Recording permission — requesting")
            CGRequestScreenCaptureAccess()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == self.displayID }) else {
                    self.fail("Display \(self.displayID) is not available for capture")
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: self.makeConfiguration(), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                try await stream.startCapture()
                self.stream = stream
                let size = Self.pixelSize(of: self.displayID)
                print("[capture] display \(self.displayID) \(size.width)x\(size.height) started")
            } catch {
                let denied = !CGPreflightScreenCaptureAccess()
                self.fail(denied
                    ? "Screen Recording permission needed: System Settings → Privacy & Security → Screen & System Audio Recording → PSVR2Player, then restart"
                    : "Screen capture failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
            print("[capture] stopped")
        }
    }

    // Call after the display's mode changes: new size for the stream
    func updateSize() {
        guard let stream else { return }
        Task {
            do {
                try await stream.updateConfiguration(makeConfiguration())
                let size = Self.pixelSize(of: displayID)
                print("[capture] resized to \(size.width)x\(size.height)")
            } catch {
                print("[capture] !!! resize failed: \(error.localizedDescription)")
            }
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let size = Self.pixelSize(of: displayID)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private func fail(_ message: String) {
        print("[capture] !!! \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }

    // MARK: SCStreamOutput (on outputQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only .complete frames carry new content; .idle means "nothing
        // changed" — keep showing the last texture
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let cache = textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let src = CVMetalTextureGetTexture(cvTexture),
              let dst = backTexture(width: width, height: height),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return }

        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: dst)
        blit.endEncoding()
        // The IOSurface must stay alive (and not be reused by SCStream) until
        // the copy has run; publish the texture only once it is complete
        cmd.addCompletedHandler { [weak self] _ in
            withExtendedLifetime((sampleBuffer, cvTexture)) {}
            guard let self else { return }
            self.lock.lock()
            if self.back === dst {
                self.back = self.front
                self.front = dst
            }
            self.frameCount += 1
            self.lock.unlock()
        }
        cmd.commit()
    }

    // Reuse the back texture while its size fits, otherwise make a new one
    // (first frame, or the display mode changed)
    private func backTexture(width: Int, height: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let back, back.width == width, back.height == height {
            return back
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .private
        back = device.makeTexture(descriptor: d)
        return back
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[capture] !!! stream stopped: \(error.localizedDescription)")
        self.stream = nil
    }
}
