import ScreenSaver
import Metal
import QuartzCore
import AppKit

private struct Uniforms {
    var res: SIMD2<Float> = .zero
    var time: Float = 0
    var camDist: Float = 0
    var incl: Float = 0
    var azim: Float = 0
    var steps: Float = 0
    var exposure: Float = 0
}

@objc(BlackHoleView)
final class BlackHoleView: ScreenSaverView {

    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private var startTime = CACurrentMediaTime()
    private var maxDrawableSide: CGFloat = 2200

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        maxDrawableSide = isPreview ? 480 : 2200
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        buildPipeline()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        buildPipeline()
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.backgroundColor = NSColor.black.cgColor
        layer.needsDisplayOnBoundsChange = true
        metalLayer = layer
        return layer
    }

    private func buildPipeline() {
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vsMain")
            desc.fragmentFunction = library.makeFunction(name: "fsMain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("BlackHoleSaver: shader build failed: \(error)")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let layer = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        var w = bounds.width * scale
        var h = bounds.height * scale
        guard w > 0, h > 0 else { return }
        // Cap the render resolution and let the layer upscale; the shader is
        // heavy enough that a native 5K drawable would drop frames.
        let longest = max(w, h)
        if longest > maxDrawableSide {
            let k = maxDrawableSide / longest
            w *= k
            h *= k
        }
        layer.drawableSize = CGSize(width: floor(w), height: floor(h))
    }

    override func startAnimation() {
        startTime = CACurrentMediaTime()
        super.startAnimation()
    }

    override func animateOneFrame() {
        super.animateOneFrame()
        render()
    }

    private func render() {
        guard let layer = metalLayer,
              let pipeline,
              let queue,
              layer.drawableSize.width > 0,
              let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }

        let t = Float(CACurrentMediaTime() - startTime)

        var u = Uniforms()
        u.res = SIMD2<Float>(Float(layer.drawableSize.width), Float(layer.drawableSize.height))
        u.time = t
        u.camDist = 22.0 + 2.5 * sin(t * 0.031)
        // Drift near the disk plane so the lensed far side arcs over the top,
        // but never sit exactly edge-on.
        u.incl = 0.155 + 0.115 * sin(t * 0.047 + 0.9)
        u.azim = t * 0.036
        u.steps = isPreview ? 190 : 380
        u.exposure = 1.15

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
