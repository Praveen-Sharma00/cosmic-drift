import ScreenCaptureKit
import Metal
import CoreVideo
import CoreMedia

/// Wraps one SCStream over a single display and hands the newest frame to Metal.
/// Runs only for the duration of a break, never while you are working.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private let device: MTLDevice
    private let queue = DispatchQueue(label: "eventhorizon.capture")
    private var cache: CVMetalTextureCache?
    private var stream: SCStream?

    private let lock = NSLock()
    private var held: (CVMetalTexture, MTLTexture)?
    private var firstFrame: (() -> Void)?

    private(set) var pixelSize = CGSize.zero

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return held?.1
    }

    /// - Parameter onFirstFrame: called once, on the capture queue, when a frame
    ///   with real content lands. The overlay waits for this so the swallow never
    ///   starts against an empty texture.
    func start(displayID: CGDirectDisplayID, scale: CGFloat, onFirstFrame: @escaping () -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "EventHorizon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "display \(displayID) not shareable"])
        }

        // Excluding ourselves is what stops the overlay from capturing its own
        // output and turning into an infinite mirror. Our windows are already
        // on screen at this point so the app is guaranteed to be in this list.
        let mine = content.applications.filter { $0.processID == getpid() }
        if mine.isEmpty { EHLog.write("WARN: self not in shareable apps; feedback loop possible") }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.displayP3
        cfg.showsCursor = false            // the real cursor composites above us
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        pixelSize = CGSize(width: cfg.width, height: cfg.height)

        lock.lock(); firstFrame = onFirstFrame; lock.unlock()

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        EHLog.write("stream started for display \(displayID) at \(cfg.width)x\(cfg.height)")
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        lock.lock(); held = nil; firstFrame = nil; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }

        // ScreenCaptureKit also emits idle/blank frames; those carry no usable
        // surface, so keep showing the last good one.
        if let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attach.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb), let cache else { return }

        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let mtl = CVMetalTextureGetTexture(cvTex) else { return }

        lock.lock()
        held = (cvTex, mtl)          // the CVMetalTexture must outlive the MTLTexture
        let cb = firstFrame
        firstFrame = nil
        lock.unlock()
        if cb != nil { EHLog.write("first frame \(mtl.width)x\(mtl.height)") }
        cb?()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        EHLog.write("capture stopped: \(error.localizedDescription)")
    }
}
