import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

// MARK: - Frame surfaces
//
// Raw bgra8 frames are read from the host pipe straight into a pooled, sRGB-tagged
// IOSurface. The viewer layer takes the IOSurface as `contents`, which Core Animation
// displays without the per-commit copy a memory-backed CGImage costs (6–86 ms per
// frame on the main thread). `makeImage()` wraps the same memory as a CGImage for
// everything that still wants one (snapshots, compare, cache bookkeeping).

/// One frame's pixels in an IOSurface. When the last reference goes, the surface
/// returns to its pool.
final class FrameSurface: @unchecked Sendable {
    let surface: IOSurfaceRef
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private weak var pool: FrameSurfacePool?

    init(surface: IOSurfaceRef, width: Int, height: Int, pool: FrameSurfacePool?) {
        self.surface = surface
        self.width = width
        self.height = height
        self.bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        self.pool = pool
    }

    deinit { pool?.recycle(surface, width: width, height: height) }

    var baseAddress: UnsafeMutableRawPointer { IOSurfaceGetBaseAddress(surface) }

    /// A CGImage over the surface memory (no copy). The image keeps `self` alive, so the
    /// surface is not recycled while anything still draws from it. Same pixel layout as
    /// `FrameDecoder.bgra8`: sRGB, premultiplied-first, 32-bit little-endian.
    func makeImage() -> CGImage? {
        let info = Unmanaged.passRetained(self).toOpaque()
        let size = bytesPerRow * height
        guard let provider = CGDataProvider(dataInfo: info, data: baseAddress, size: size, releaseData: { info, _, _ in
            guard let info else { return }
            Unmanaged<FrameSurface>.fromOpaque(info).release()
        }) else {
            Unmanaged<FrameSurface>.fromOpaque(info).release()
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: FrameDecoder.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Reuses IOSurfaces per size. A returned surface that Core Animation (or the window
/// server) still uses goes on a deferred list and is re-checked at the next checkout.
final class FrameSurfacePool: @unchecked Sendable {
    static let shared = FrameSurfacePool()

    /// Free surfaces kept per size.
    let maxFreePerSize: Int
    private let lock = NSLock()
    private struct Size: Hashable { var w: Int; var h: Int }
    private var free: [Size: [IOSurfaceRef]] = [:]
    private var deferred: [(Size, IOSurfaceRef)] = []
    private var lastSize: Size?
    private(set) var created = 0

    init(maxFreePerSize: Int = 8) { self.maxFreePerSize = maxFreePerSize }

    private static let colorSpace: CFPropertyList? = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()

    /// A surface of exactly `width`×`height`, or nil (caller falls back to Data).
    func checkout(width: Int, height: Int) -> FrameSurface? {
        guard width > 0, height > 0 else { return nil }
        let key = Size(w: width, h: height)
        lock.lock()
        if lastSize != key {
            // A new size (ladder step, resize): free lists for other sizes are dead weight.
            if lastSize != nil { free = free.filter { $0.key == key } }
            lastSize = key
        }
        // Deferred surfaces CA has let go of become free again.
        if !deferred.isEmpty {
            var still: [(Size, IOSurfaceRef)] = []
            for (s, sf) in deferred {
                if IOSurfaceIsInUse(sf) { still.append((s, sf)) }
                else if s == key, free[s, default: []].count < maxFreePerSize { free[s, default: []].append(sf) }
            }
            deferred = still
        }
        let reused = free[key]?.popLast()
        lock.unlock()
        if let reused { return FrameSurface(surface: reused, width: width, height: height, pool: self) }
        guard let s = Self.make(width: width, height: height) else { return nil }
        lock.withLock { created += 1 }
        return FrameSurface(surface: s, width: width, height: height, pool: self)
    }

    func recycle(_ s: IOSurfaceRef, width: Int, height: Int) {
        let key = Size(w: width, h: height)
        lock.lock(); defer { lock.unlock() }
        guard key == lastSize else { return }
        if IOSurfaceIsInUse(s) {
            if deferred.count < maxFreePerSize * 2 { deferred.append((key, s)) }
        } else if free[key, default: []].count < maxFreePerSize {
            free[key, default: []].append(s)
        }
    }

    /// Free surfaces currently pooled (tests).
    var freeCount: Int { lock.withLock { free.values.reduce(0) { $0 + $1.count } } }

    static func make(width: Int, height: Int) -> IOSurfaceRef? {
        let props: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let s = IOSurfaceCreate(props as CFDictionary) else { return nil }
        if let cs = colorSpace { IOSurfaceSetValue(s, kIOSurfaceColorSpace, cs) }
        return s
    }
}
