import CoreVideo
import Foundation

/// A tiny grayscale fingerprint of a frame.
///
/// Two measurements come out of the same grid, deliberately, so the gate costs
/// one pass over the pixel buffer and nothing else:
///
/// 1. **Luminance delta** — the mean absolute luminance change, normalized to
///    0…1. This is the spec's "delta < 3%" rule and it is what actually decides
///    whether the screen is static.
/// 2. **Difference-hash similarity** — `phash_similarity_threshold` from the
///    skill config. It catches frames whose *raw pixels* moved barely (a caret
///    blink, a clock, a progress bar) but whose content is perceptually
///    unchanged, which a raw delta on its own would let through.
///
/// The grid is sampled with integer math straight out of the pixel buffer's
/// base address, so producing a thumbprint allocates nothing but the 4 KB
/// result and never copies the frame.
struct PerceptualThumbnail: Sendable {

    /// One side of the square grid, in samples.
    let resolution: Int

    /// Row-major luminance values, 0…255.
    let gray: [UInt8]

    /// Samples a grid out of a BGRA pixel buffer.
    ///
    /// Returns `nil` if the buffer cannot be locked or is too small to sample,
    /// which means the caller should treat the frame as significant rather than
    /// silently dropping it.
    static func sample(from pixelBuffer: CVPixelBuffer, resolution: Int) -> PerceptualThumbnail? {
        guard resolution > 0 else { return nil }

        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard width >= resolution, height >= resolution, bytesPerRow > 0 else { return nil }

        let bytesPerPixel = 4

        var gray = [UInt8](repeating: 0, count: resolution * resolution)
        for row in 0..<resolution {
            // Sample the centre of each cell so no pixel is systematically
            // privileged at the edges.
            let sourceY = ((row * height) / resolution).clamped(to: 0..<height)
            let rowPointer = baseAddress.advanced(by: sourceY * bytesPerRow)

            for column in 0..<resolution {
                let sourceX = ((column * width) / resolution).clamped(to: 0..<width)
                let pixel = rowPointer
                    .advanced(by: sourceX * bytesPerPixel)
                    .assumingMemoryBound(to: UInt8.self)

                // BGRA: B, G, R, A. Rec.601 luma, in integer math.
                let blue = Int(pixel[0])
                let green = Int(pixel[1])
                let red = Int(pixel[2])
                let luminance = (red * 299 + green * 587 + blue * 114) / 1000
                gray[(row * resolution) + column] = UInt8(clamping: luminance)
            }
        }

        return PerceptualThumbnail(resolution: resolution, gray: gray)
    }

    /// Mean absolute luminance difference, normalized to 0…1.
    ///
    /// 0 is an identical screen; 1 is black flipping to white.
    func delta(from other: PerceptualThumbnail) -> Double {
        guard resolution == other.resolution, gray.count == other.gray.count else {
            // A dimension change is maximally significant — never drop it.
            return 1.0
        }

        var total = 0
        for index in gray.indices {
            total += abs(Int(gray[index]) - Int(other.gray[index]))
        }
        let mean = Double(total) / Double(gray.count)
        return mean / 255.0
    }

    /// Fraction of difference-hash bits that agree, 0…1.
    ///
    /// The hash is a 64-bit horizontal-gradient dHash taken across the whole
    /// image, not a corner, so a shifted clock still reads as "similar".
    func differenceHashSimilarity(to other: PerceptualThumbnail) -> Double {
        let mine = differenceHash
        let theirs = other.differenceHash
        let distance = (mine ^ theirs).nonzeroBitCount
        return 1.0 - (Double(distance) / 64.0)
    }

    /// 64 bits: each bit compares a sample against its right-hand neighbour
    /// along a row, with 9 columns sampled across the full width.
    var differenceHash: UInt64 {
        let columns = 9
        let rows = 8
        var hash: UInt64 = 0

        for row in 0..<rows {
            let y = ((row * resolution) / rows).clamped(to: 0..<resolution)
            for column in 0..<rows {
                let left = ((column * resolution) / columns).clamped(to: 0..<resolution)
                let right = (((column + 1) * resolution) / columns).clamped(to: 0..<resolution)
                let indexLeft = (y * resolution) + left
                let indexRight = (y * resolution) + right
                hash = (hash << 1) | UInt64(gray[indexLeft] < gray[indexRight] ? 1 : 0)
            }
        }
        return hash
    }
}

private extension Comparable {
    func clamped(to range: Range<Self>) -> Self {
        if self < range.lowerBound { return range.lowerBound }
        if self >= range.upperBound { return range.upperBound }
        return self
    }
}
