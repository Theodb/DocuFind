#!/usr/bin/env swift
import AppKit
import Foundation

// The DocuFind mark: a painted, speckled tile (the search aura's colours) under a
// flat deep-teal magnifier whose lens enlarges the paint beneath it.
// The painting is rendered once at 1024 px and scaled, so small sizes blend smoothly.

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

// MARK: Painting

let palette: [SIMD3<Float>] = [(155, 225, 93), (54, 197, 240), (255, 216, 77), (255, 122, 198)]
    .map { SIMD3<Float>(Float($0.0), Float($0.1), Float($0.2)) / 255 }

func hash(_ x: Float, _ y: Float) -> Float {
    var p = SIMD2<Float>(x, y) * SIMD2<Float>(233.34, 851.73)
    p = p - p.rounded(.down)
    let d = (p * (p + 23.45)).sum()
    p += d
    let v = p.x * p.y
    return v - v.rounded(.down)
}

func noise(_ x: Float, _ y: Float) -> Float {
    let ix = x.rounded(.down), iy = y.rounded(.down)
    let fx = x - ix, fy = y - iy
    let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
    let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
}

func fbm(_ x: Float, _ y: Float) -> Float {
    var value: Float = 0, amplitude: Float = 0.5, px = x, py = y
    for _ in 0..<4 {
        value += amplitude * noise(px, py)
        (px, py) = (1.6 * px - 1.2 * py + 3.1, 1.2 * px + 1.6 * py + 3.1)
        amplitude *= 0.5
    }
    return value
}

func ramp(_ t: Float) -> SIMD3<Float> {
    let s = max(0, min(1, t)) * 3
    let i = min(2, Int(s)), f = s - Float(i)
    let k = f * f * (3 - 2 * f)
    return palette[i] + (palette[i + 1] - palette[i]) * k
}

/// Diagonal colour field with an fbm warp, sampled per speck at a jittered nearby point.
func painting(side: Int) -> CGImage {
    let angle: Float = 0.62
    let dr = SIMD2<Float>(cos(angle), sin(angle)), pp = SIMD2<Float>(-dr.y, dr.x)
    func field(_ a: SIMD2<Float>) -> SIMD3<Float> {
        let u = (a * dr).sum(), v = (a * pp).sum()
        let q = fbm(u * 1.4 + 2.2, v * 4 + 3.7) - 0.5
        let q2 = fbm(a.x * 2.3 + 6.8, a.y * 2.3 + 6.8) - 0.5
        return ramp(u * 0.8 + 0.5 + q * 0.65 + q2 * 0.35)
    }
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    let grain: Float = 2.2
    for y in 0..<side {
        for x in 0..<side {
            let px = Float(x), py = Float(side - 1 - y)
            let cx = (px / grain).rounded(.down), cy = (py / grain).rounded(.down)
            let a = (SIMD2<Float>(px, py) - Float(side) / 2) / Float(side)
            let jitter = SIMD2<Float>(hash(cx, cy), hash(cx + 17.31, cy + 17.31)) - 0.5
            var c = field(a + dr * jitter.x * 0.12 + pp * jitter.y * 0.05)
            if hash(cx + 41.3, cy + 41.3) > 0.92 { c = c + (palette[Int(hash(cx + 7.7, cy + 7.7) * 4) % 4] - c) * 0.6 }
            c += SIMD3<Float>(hash(cx + 3.17, cy + 3.17), hash(cx + 5.71, cy + 5.71), hash(cx + 9.23, cy + 9.23)) * 0.26 - 0.13
            if hash(cx + 21.7, cy + 21.7) > 0.93 { c = c + (SIMD3<Float>(repeating: 0.98) - c) * 0.4 }
            let i = (y * side + x) * 4
            pixels[i] = UInt8(max(0, min(1, c.x)) * 255)
            pixels[i + 1] = UInt8(max(0, min(1, c.y)) * 255)
            pixels[i + 2] = UInt8(max(0, min(1, c.z)) * 255)
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

// MARK: Icon

func drawIcon(size: Int, paint: CGImage, destination: URL) throws {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // The inset follows the macOS app-icon grid and leaves room for a soft shadow.
    let tileRect = CGRect(x: 64, y: 64, width: 896, height: 896)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 202, cornerHeight: 202, transform: nil)
    context.saveGState()
    // Shadow offset and blur are in device pixels, so they scale with the icon or small sizes get a grey haze.
    let pixels = CGFloat(size) / 1024
    context.setShadow(offset: CGSize(width: 0, height: -12 * pixels), blur: 26 * pixels, color: color(40, 30, 70, alpha: 0.25))
    context.addPath(tile)
    context.setFillColor(color(200, 220, 160))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.draw(paint, in: tileRect)
    // Soft top light, like a sheet of glass over the canvas.
    let light = CGGradient(colorsSpace: nil, colors: [color(255, 255, 255, alpha: 0.32), color(255, 255, 255, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(light, startCenter: CGPoint(x: 260, y: 940), startRadius: 0, endCenter: CGPoint(x: 260, y: 940), endRadius: 760, options: [])
    context.restoreGState()

    context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), cornerWidth: 200, cornerHeight: 200, transform: nil))
    context.setLineWidth(4)
    context.setStrokeColor(color(255, 255, 255, alpha: 0.6))
    context.strokePath()

    // A flat deep-teal magnifier, centred on the tile. Its lens enlarges the paint beneath.
    // Geometry in top-down pixels: ring centre 457.5, outer radius 240, inner 171, handle 101 wide ending at 747.5.
    // These follow a classic system-glyph balance (slim ring, handle reaching ~1.9 radii); the shape is our own.
    let center = CGPoint(x: 457.5, y: 1024 - 457.5), outer: CGFloat = 240, inner: CGFloat = 171
    let handleWidth: CGFloat = 101, handleEnd = CGPoint(x: 747.5, y: 1024 - 747.5)
    let ink = color(6, 64, 78)
    func magnifier() -> CGPath {
        let ring = CGPath(ellipseIn: CGRect(x: center.x - (outer + inner) / 2, y: center.y - (outer + inner) / 2,
                                            width: outer + inner, height: outer + inner), transform: nil)
            .copy(strokingWithWidth: outer - inner, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        // Square where it meets the ring (a round start would bulge into the lens), round at the end.
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: center.x + outer * 0.62, y: center.y - outer * 0.62))
        handle.addLine(to: handleEnd)
        let cap = CGPath(ellipseIn: CGRect(x: handleEnd.x - handleWidth / 2, y: handleEnd.y - handleWidth / 2,
                                           width: handleWidth, height: handleWidth), transform: nil)
        return ring.union(handle.copy(strokingWithWidth: handleWidth, lineCap: .butt, lineJoin: .round, miterLimit: 1)).union(cap)
    }

    let lensRect = CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)
    context.saveGState()
    context.addEllipse(in: lensRect)
    context.clip()
    let zoom: CGFloat = 1.5
    context.draw(paint, in: CGRect(x: center.x - (center.x - tileRect.minX) * zoom, y: center.y - (center.y - tileRect.minY) * zoom,
                                   width: tileRect.width * zoom, height: tileRect.height * zoom))
    let sheenCenter = CGPoint(x: center.x - inner * 0.45, y: center.y + inner * 0.45)
    let sheen = CGGradient(colorsSpace: nil, colors: [color(255, 255, 255, alpha: 0.35), color(255, 255, 255, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(sheen, startCenter: sheenCenter, startRadius: 0, endCenter: sheenCenter, endRadius: inner * 0.9, options: [])
    context.restoreGState()

    context.addPath(magnifier())
    context.setFillColor(ink)
    context.fillPath()

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: destination)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift /path/to/DocuFind.iconset\n", stderr)
    exit(1)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let paint = painting(side: 1024)
for points in [16, 32, 128, 256, 512] {
    try drawIcon(size: points, paint: paint, destination: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(size: points * 2, paint: paint, destination: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
