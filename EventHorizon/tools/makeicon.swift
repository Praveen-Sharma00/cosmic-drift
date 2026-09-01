// Renders AppIcon.icns using the real black hole shader, so the icon is the
// thing itself rather than a drawing of it.
// Usage: swiftc -O -o makeicon makeicon.swift ../Shaders.swift && ./makeicon <outdir>

import Metal
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct Uniforms {
    var capSize = SIMD2<Float>(1, 1); var winOriginCap = SIMD2<Float>(0, 0)
    var holeCap = SIMD2<Float>(0, 0); var pad2 = SIMD2<Float>(0, 0)
    var pxPerUnit: Float = 1; var camDist: Float = 20; var planeDist: Float = 35
    var time: Float = 0; var incl: Float = 0.16; var roll: Float = 0
    var maxSteps: Float = 480; var exposure: Float = 1.15; var diskGain: Float = 3.4
    var fade: Float = 1; var swirl: Float = 0; var warpReach: Float = 4000
    var frontX: Float = 1e9; var frontSoft: Float = 1
    var mixLeft: Float = 0; var mixRight: Float = 0        // sky only, no desktop
}

let S = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let lib: MTLLibrary
do { lib = try device.makeLibrary(source: shaderSource, options: nil) }
catch { print("shader failed: \(error)"); exit(1) }

let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = lib.makeFunction(name: "vsMain")
pd.fragmentFunction = lib.makeFunction(name: "fsMain")
pd.colorAttachments[0].pixelFormat = .rgba8Unorm
let pipe = try! device.makeRenderPipelineState(descriptor: pd)

let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                  width: S, height: S, mipmapped: false)
td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
let target = device.makeTexture(descriptor: td)!
let dummy = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))!

var u = Uniforms()
u.capSize = SIMD2(Float(S), Float(S))
u.holeCap = SIMD2(Float(S) * 0.5, Float(S) * 0.5)
// Sized so the disk's outer edge sits inside the icon's rounded square.
u.pxPerUnit = 99 * u.camDist / 2.598076
u.incl = 0.34                       // opened up a little so it reads as a disk
u.roll = 0.0
u.time = 18.0

let rp = MTLRenderPassDescriptor()
rp.colorAttachments[0].texture = target
rp.colorAttachments[0].loadAction = .clear
rp.colorAttachments[0].storeAction = .store
rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
let cb = queue.makeCommandBuffer()!
let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
enc.setRenderPipelineState(pipe)
enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
enc.setFragmentTexture(dummy, index: 0)
enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

var px = [UInt8](repeating: 0, count: S * S * 4)
target.getBytes(&px, bytesPerRow: S * 4, from: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bmp = CGImageAlphaInfo.premultipliedLast.rawValue
let holeCtx = CGContext(data: &px, width: S, height: S, bitsPerComponent: 8,
                        bytesPerRow: S * 4, space: cs, bitmapInfo: bmp)!
let holeImg = holeCtx.makeImage()!

// Compose onto the rounded square macOS expects, with padding for the shadow.
let canvas = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                       bytesPerRow: S * 4, space: cs, bitmapInfo: bmp)!
let inset: CGFloat = 100
let plate = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
let squircle = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

canvas.saveGState()
canvas.addPath(squircle)
canvas.clip()
// Deep space gradient behind the hole.
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.055, green: 0.055, blue: 0.086, alpha: 1),
    CGColor(red: 0.012, green: 0.012, blue: 0.024, alpha: 1)] as CFArray, locations: [0, 1])!
canvas.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(S)),
                          end: CGPoint(x: 0, y: 0), options: [])
canvas.draw(holeImg, in: CGRect(x: 0, y: 0, width: S, height: S))
canvas.restoreGState()

let final = canvas.makeImage()!

func writePNG(_ img: CGImage, _ side: Int, _ name: String) {
    let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: cs, bitmapInfo: bmp)!
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
    let url = URL(fileURLWithPath: "\(outDir)/\(name)")
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil)
    CGImageDestinationFinalize(d)
}

for base in [16, 32, 128, 256, 512] {
    writePNG(final, base, "icon_\(base)x\(base).png")
    writePNG(final, base * 2, "icon_\(base)x\(base)@2x.png")
}
print("wrote iconset PNGs to \(outDir)")
