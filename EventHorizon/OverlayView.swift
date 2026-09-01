import AppKit
import Metal
import QuartzCore

/// Animation state for one rendered frame, driven by BreakController.
struct ArcState {
    var holePoints: CGFloat = 95     // apparent shadow radius, in points
    var holeX: CGFloat = 0.5         // fraction across the display; may leave [0,1]
    var holeY: CGFloat = 0.44
    var warpPoints: CGFloat = 420    // distortion decays to nothing beyond this
    var frontX: CGFloat = 2          // consumption front, as a fraction across
    var frontSoftPoints: CGFloat = 300
    var mixLeft: Float = 0           // desktop visibility behind the front
    var mixRight: Float = 1          // desktop visibility ahead of it
    var swirl: Float = 0
    var fade: Float = 0
    var timeScale: Float = 1   // scales the disk's own motion
}

private struct Uniforms {
    var capSize = SIMD2<Float>(1, 1)
    var winOriginCap = SIMD2<Float>(0, 0)
    var holeCap = SIMD2<Float>(0, 0)
    var hasDesktop: Float = 1
    var pad0: Float = 0
    var pxPerUnit: Float = 1
    var camDist: Float = 20
    var planeDist: Float = 35
    var time: Float = 0
    var incl: Float = 0.16
    var roll: Float = 0
    var maxSteps: Float = 320
    var exposure: Float = 1.15
    var diskGain: Float = 2.0
    var fade: Float = 0
    var swirl: Float = 0
    var warpReach: Float = 800
    var frontX: Float = 1e9
    var frontSoft: Float = 600
    var mixLeft: Float = 1
    var mixRight: Float = 1
}

private let BC: Float = 2.598076   // photon capture impact parameter / rs

final class OverlayView: NSView {

    var arc = ArcState()
    var capture: ScreenCapture?
    /// Seed so each display's hole is not in lockstep with the others.
    var phase: Float = 0

    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private var blank: MTLTexture?
    private var start = CACurrentMediaTime()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.isOpaque = false
        l.framebufferOnly = true
        l.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        l.backgroundColor = .clear
        metalLayer = l
        return l
    }

    private func build() {
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vsMain")
            d.fragmentFunction = lib.makeFunction(name: "fsMain")
            let att = d.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true          // premultiplied source
            att.sourceRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("EventHorizon: shader build failed: \(error)")
        }
        // Bound whenever screen capture is unavailable; the effect then plays
        // against the starfield alone.
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 1, height: 1, mipmapped: false)
        bd.usage = .shaderRead
        blank = device.makeTexture(descriptor: bd)
        var px: UInt32 = 0
        blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                       withBytes: &px, bytesPerRow: 4)
    }

    override func layout() {
        super.layout()
        guard let l = metalLayer else { return }
        let s = window?.backingScaleFactor ?? 2
        l.contentsScale = s
        guard bounds.width > 0, bounds.height > 0 else { return }
        l.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }

    func resetClock() { start = CACurrentMediaTime() }

    func render() {
        guard let l = metalLayer, let pipeline, let queue,
              l.drawableSize.width > 1,
              let drawable = l.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }

        let t = Float(CACurrentMediaTime() - start) * arc.timeScale
        let scale = Float(window?.backingScaleFactor ?? 2)
        let dw = Float(l.drawableSize.width), dh = Float(l.drawableSize.height)

        var u = Uniforms()
        u.time = t

        let tex = capture?.texture
        var haveDesktop = true
        if let tex {
            u.capSize = SIMD2(Float(tex.width), Float(tex.height))
        } else {
            u.capSize = SIMD2(dw, dh)
            haveDesktop = false
        }
        // Our window covers its whole display, so the drawable and the capture
        // share an origin and a scale.
        u.winOriginCap = SIMD2(0, 0)

        let cw = u.capSize.x, ch = u.capSize.y
        // holeX is driven by the sweep; the bob keeps it off a dead straight rail.
        let bob = 0.035 * sin(t * 0.55 + phase)
        u.holeCap = SIMD2(cw * Float(arc.holeX), ch * (Float(arc.holeY) + bob))

        let shadowPx = max(Float(arc.holePoints) * scale, 2)
        u.pxPerUnit = shadowPx * u.camDist / BC
        u.warpReach = max(Float(arc.warpPoints) * scale, shadowPx * 1.5)
        u.incl = 0.155 + 0.10 * sin(t * 0.047 + 0.9)
        u.roll = 0.30 * sin(t * 0.020 + phase)
        u.fade = arc.fade
        u.swirl = arc.swirl
        u.frontX = cw * Float(arc.frontX)
        u.frontSoft = max(Float(arc.frontSoftPoints) * scale, 1)
        // With no capture there is no desktop to eat, so play against the sky -
        // but keep it local rather than taking over the whole screen.
        u.hasDesktop = haveDesktop ? 1 : 0
        u.mixLeft = haveDesktop ? arc.mixLeft : 0
        u.mixRight = haveDesktop ? arc.mixRight : 0

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(tex ?? blank, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cb.present(drawable)
        cb.commit()
    }
}
