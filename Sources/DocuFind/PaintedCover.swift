import CoreGraphics
import Foundation
import SwiftUI
import simd

/// Four-colour ramp used by a painted cover. Values are 0...1 sRGB.
struct CoverPalette: Hashable, Sendable {
    let colors: [SIMD3<Float>]

    init(hex: [UInt32]) {
        colors = hex.map { value in
            SIMD3<Float>(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
        }
    }

    /// Theme palettes: garden, money, work, travel, sound, colour, home.
    static let all: [CoverPalette] = [
        CoverPalette(hex: [0x2BB673, 0x9BE15D, 0xFFD84D, 0x36C5F0]),
        CoverPalette(hex: [0xFF9F5A, 0xFFD84D, 0x9BE15D, 0xFF8FB1]),
        CoverPalette(hex: [0x36C5F0, 0x9BE15D, 0x4F7BFF, 0x9B7BFF]),
        CoverPalette(hex: [0x36C5F0, 0x4F7BFF, 0xFFA26B, 0xFF7AC6]),
        CoverPalette(hex: [0x9B7BFF, 0x4F7BFF, 0xFF7AC6, 0x36C5F0]),
        CoverPalette(hex: [0xFF7AC6, 0xFF5A5F, 0xFFA26B, 0x9B7BFF]),
        CoverPalette(hex: [0xFFA26B, 0xFFD84D, 0xFF7AC6, 0x9BE15D]),
    ]
    static let aura = CoverPalette(hex: [0x9BE15D, 0x36C5F0, 0xFFD84D, 0xFF7AC6])

    /// Each kind of file has its own colour family, so documents, photos and recordings read apart at a glance.
    static let documents = CoverPalette(hex: [0x2BB673, 0x9BE15D, 0xFFD84D, 0x36C5F0])
    static let photos = CoverPalette(hex: [0xFF9F5A, 0xFFD84D, 0xFF7AC6, 0xFF5A5F])
    static let recordings = CoverPalette(hex: [0x9B7BFF, 0x4F7BFF, 0xFF7AC6, 0x36C5F0])
    static func forKind(_ kind: String) -> CoverPalette {
        kind == "image" ? photos : kind == "audio" ? recordings : documents
    }

    /// Stable choice for a key, so files in the same folder share a palette.
    static func forKey(_ key: String) -> CoverPalette {
        all[Int(PaintedCoverRenderer.fnv1a(key) % UInt32(all.count))]
    }
}

/// Renders and caches painted covers. Rendering happens off the actor so
/// several covers can be painted at once; identical requests share one task.
actor PaintedCoverCache {
    static let shared = PaintedCoverCache()

    private final class Entry { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    /// Read synchronously by views, so a cover scrolling back into view shows at once (NSCache is thread-safe).
    nonisolated func cached(key: String, palette: CoverPalette, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        cache.object(forKey: "\(key)|\(palette.hashValue)|\(pixelWidth)x\(pixelHeight)" as NSString)?.image
    }

    private nonisolated(unsafe) let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    /// `key` identifies the artwork (its seed and angle); size is in device pixels.
    func image(key: String, palette: CoverPalette, pixelWidth: Int, pixelHeight: Int) async -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let id = "\(key)|\(palette.hashValue)|\(pixelWidth)x\(pixelHeight)"
        if let entry = cache.object(forKey: id as NSString) { return entry.image }
        if let task = inFlight[id] { return await task.value }
        let task = Task.detached(priority: .utility) {
            PaintedCoverRenderer.render(key: key, palette: palette, width: pixelWidth, height: pixelHeight)
        }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        if let image { cache.setObject(Entry(image), forKey: id as NSString, cost: pixelWidth * pixelHeight * 4) }
        return image
    }
}

/// A painted cover that fills its frame. Shows a soft gradient of the palette
/// until the speckled painting is ready, then fades it in.
struct PaintedCoverView: View {
    let key: String
    let palette: CoverPalette
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private struct RenderID: Hashable { let key: String; let palette: CoverPalette; let width: Int; let height: Int }

    var body: some View {
        GeometryReader { proxy in
            let width = Int((proxy.size.width * displayScale).rounded())
            let height = Int((proxy.size.height * displayScale).rounded())
            ZStack {
                LinearGradient(colors: palette.colors.map { Color(.sRGB, red: Double($0.x), green: Double($0.y), blue: Double($0.z)) },
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: RenderID(key: key, palette: palette, width: width, height: height)) {
                // Already painted (a card scrolling back into view): shown at once, without a fade.
                if let known = PaintedCoverCache.shared.cached(key: key, palette: palette, pixelWidth: width, pixelHeight: height) {
                    image = known
                    return
                }
                let rendered = await PaintedCoverCache.shared.image(key: key, palette: palette, pixelWidth: width, pixelHeight: height)
                guard !Task.isCancelled, let rendered else { return }
                withAnimation(.easeOut(duration: 0.25)) { image = rendered }
            }
        }
        .accessibilityHidden(true)
    }
}

/// CPU port of the prototype's pastel-speckle shader. The smooth colour field
/// is evaluated on a coarse grid; per-pixel work is limited to cheap hashes.
enum PaintedCoverRenderer {
    static func fnv1a(_ string: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in string.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return hash
    }

    @inline(__always) private static func hash(_ x: Int32, _ y: Int32, _ salt: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343 ^ UInt32(bitPattern: y) &* 0xD816_3841 ^ salt &* 0xCB1A_B31F
        h ^= h >> 15; h &*= 0x2C1B_3C6D; h ^= h >> 12; h &*= 0x297A_2D39; h ^= h >> 15
        return Float(h >> 8) * (1 / 16_777_216)
    }

    @inline(__always) private static func noise(_ x: Float, _ y: Float, _ salt: UInt32 = 0) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(truncatingIfNeeded: Int(fx)), iy = Int32(truncatingIfNeeded: Int(fy))
        let tx = x - fx, ty = y - fy
        let ux = tx * tx * (3 - 2 * tx), uy = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy, salt), b = hash(ix &+ 1, iy, salt)
        let c = hash(ix, iy &+ 1, salt), d = hash(ix &+ 1, iy &+ 1, salt)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    private static func fbm(_ x: Float, _ y: Float) -> Float {
        var value: Float = 0, amplitude: Float = 0.5, px = x, py = y
        for _ in 0..<4 {
            value += amplitude * noise(px, py)
            (px, py) = (1.6 * px - 1.2 * py + 3.1, 1.2 * px + 1.6 * py + 3.1)
            amplitude *= 0.5
        }
        return value
    }

    @inline(__always) private static func ramp(_ t: Float, _ k: [SIMD3<Float>]) -> SIMD3<Float> {
        let s = min(max(t, 0), 1) * 3
        func step(_ e0: Float, _ x: Float) -> Float { let v = min(max(x - e0, 0), 1); return v * v * (3 - 2 * v) }
        var c = k[0] + (k[1] - k[0]) * step(0, s)
        c += (k[2] - c) * step(1, s)
        return c + (k[3] - c) * step(2, s)
    }

    static func render(key: String, palette: CoverPalette, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, palette.colors.count == 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        let k = palette.colors
        let h0 = fnv1a(key), h1 = fnv1a(key + "a")
        let seed = Float(h0 % 1000) / 37
        let angle = 0.35 + Float(h1 % 100) / 100 * 0.5
        let dr = SIMD2<Float>(cos(angle), sin(angle)), pp = SIMD2<Float>(-dr.y, dr.x)
        let W = Float(width), H = Float(height), invH = 1 / H
        let salt = h0

        // Coarse grid: colour field and streak warp, sampled bilinearly below.
        let step = 4, gw = width / step + 3, gh = height / step + 3
        var field = [SIMD3<Float>](repeating: .zero, count: gw * gh)
        var warp = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                // Shader space: origin at centre, y up, units of height.
                let ax = (Float(gx * step) - 0.5 * W) * invH
                let ay = (0.5 * H - Float(gy * step)) * invH
                let u = ax * dr.x + ay * dr.y, v = ax * pp.x + ay * pp.y
                let q = fbm(u * 1.4 + seed, v * 4 + seed * 1.7) - 0.5
                let q2 = fbm(ax * 2.3 + seed * 3.1, ay * 2.3 + seed * 3.1) - 0.5
                field[gy * gw + gx] = ramp(u * 0.8 + 0.5 + q * 0.65 + q2 * 0.35, k)
                warp[gy * gw + gx] = fbm(ax * 6 + seed, ay * 6 + seed) * 3
            }
        }
        @inline(__always) func sample<T>(_ grid: [T], _ x: Float, _ y: Float, _ lerp: (T, T, Float) -> T) -> T {
            let gx = min(max(x / Float(step), 0), Float(gw - 2)), gy = min(max(y / Float(step), 0), Float(gh - 2))
            let ix = Int(gx), iy = Int(gy), tx = gx - Float(ix), ty = gy - Float(iy)
            let i = iy * gw + ix
            return lerp(lerp(grid[i], grid[i + 1], tx), lerp(grid[i + gw], grid[i + gw + 1], tx), ty)
        }
        let lerp3: (SIMD3<Float>, SIMD3<Float>, Float) -> SIMD3<Float> = { $0 + ($1 - $0) * $2 }
        let lerp1: (Float, Float, Float) -> Float = { $0 + ($1 - $0) * $2 }

        let grain = max(Float(1.4), H / 190)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let paper = SIMD3<Float>(repeating: 0.98)
        for py in 0..<height {
            let cy = Int32(Float(py) / grain)
            let ay = (0.5 * H - Float(py)) * invH
            for px in 0..<width {
                let cx = Int32(Float(px) / grain)
                // Each speck borrows colour from a jittered point nearby.
                let jx = hash(cx, cy, salt) - 0.5, jy = hash(cx, cy, salt &+ 17) - 0.5
                let off = (dr * (jx * 0.12) + pp * (jy * 0.05)) * H
                var c = sample(field, Float(px) + off.x, Float(py) - off.y, lerp3)
                if hash(cx, cy, salt &+ 41) > 0.92 {
                    c += (k[Int(hash(cx, cy, salt &+ 7) * 3.999)] - c) * 0.6
                }
                c += SIMD3(hash(cx, cy, salt &+ 3), hash(cx, cy, salt &+ 5), hash(cx, cy, salt &+ 9)) * 0.26 - 0.13
                // Faint diagonal chalk streaks.
                let ax = (Float(px) - 0.5 * W) * invH
                let w = sample(warp, Float(px), Float(py), lerp1)
                let s = noise((ax * pp.x + ay * pp.y) * 150 + w, (ax * dr.x + ay * dr.y) * 10 + w, 1)
                c *= 0.94 + 0.11 * s
                if hash(cx, cy, salt &+ 21) > 0.93 { c += (paper - c) * 0.4 }
                c = simd_clamp(c, .zero, .one) * 255
                let o = (py * width + px) * 4
                pixels[o] = UInt8(c.x); pixels[o + 1] = UInt8(c.y); pixels[o + 2] = UInt8(c.z); pixels[o + 3] = 255
            }
        }
        return context.makeImage()
    }
}
