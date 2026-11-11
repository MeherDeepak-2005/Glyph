import Foundation
import CoreGraphics

// Glide path preprocessing (P2) — turns a raw swipe trajectory into the input the
// trie decoder (P3) consumes: an evenly-resampled polyline in the spatial model's
// KEY-GRID coordinates (q = (0,0), w = (1,0) … same space as KB.pos), with pivots
// marking where the finger slowed or turned — the likely intended letters.

/// A snapshot of the letter-key layout at the moment a swipe lifts, so the decoder
/// can map the swipe's VIEW-space points into grid space. Built by KeyboardView
/// (which knows the on-screen frames); consumed by the engine (which knows KB.pos).
nonisolated struct GlideLayout {
	let centers: [(letter: Character, point: CGPoint)]   // view-space key centers
	let xPitch: CGFloat                                  // key column pitch (view units)
	let yPitch: CGFloat                                  // key row pitch (view units)
}

/// A preprocessed swipe in grid space.
nonisolated struct ProcessedGlide {
	let points: [CGPoint]        // evenly spaced, grid coordinates
	let pivots: [Int]            // indices into `points` at direction turns AND velocity minima
	/// Letters the finger DWELLED on — a velocity minimum sustained near a key center (needs
	/// timestamps). These are the positive evidence for a doubled letter (#5): a swipe traces
	/// no loop for "ll", but the hand naturally lingers, so a dwell at `l` favours "hello" over
	/// "helo" where the shape alone ties. Empty when no timestamps were supplied.
	let dwellKeys: [Character]
}


/// Numeric boundary buffers; no geometry algorithms run in these conversions.
nonisolated enum GlideBuffers {
    static func points(_ points: [CGPoint]) -> Data {
        points.flatMap { [Double($0.x), Double($0.y)] }.withUnsafeBytes { Data($0) }
    }
    static func points(_ data: Data) -> [CGPoint] {
        data.withUnsafeBytes { bytes in stride(from: 0, to: data.count, by: 16).map {
            CGPoint(x: bytes.loadUnaligned(fromByteOffset: $0, as: Double.self),
                y: bytes.loadUnaligned(fromByteOffset: $0 + 8, as: Double.self))
        } }
    }
    static func keys(_ layout: GlideLayout) -> Data { Data(layout.centers.map { $0.letter.asciiValue ?? 0 }) }
    static func letters(_ data: Data) -> [Character] { data.map { Character(UnicodeScalar($0)) } }
}
nonisolated enum GlidePreprocess {
    static func run(_ raw: [CGPoint], layout: GlideLayout, spacing: CGFloat = 0.5,
                    times: [TimeInterval]? = nil) -> ProcessedGlide? {
        let stamps = times.map { $0.withUnsafeBytes { Data($0) } }
        guard let result = KBNativeGlide.preprocess(GlideBuffers.points(raw), keys: GlideBuffers.keys(layout),
            centers: GlideBuffers.points(layout.centers.map(\.point)), xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch),
            spacing: Double(spacing), times: stamps) else { return nil }
        return ProcessedGlide(points: GlideBuffers.points(result.points), pivots: result.pivots.map(\.intValue),
            dwellKeys: GlideBuffers.letters(result.dwell))
    }
    static func gridPoints(_ points: [CGPoint], layout: GlideLayout) -> [CGPoint] {
        GlideBuffers.points(KBNativeGlide.toGrid(GlideBuffers.points(points), keys: GlideBuffers.keys(layout),
            centers: GlideBuffers.points(layout.centers.map(\.point)), xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch)))
    }
    static func toGrid(_ p: CGPoint, layout: GlideLayout) -> CGPoint { gridPoints([p], layout: layout)[0] }
}
/// Shape cost of a word's ideal path against a processed swipe (band-DTW in key-grid units).
nonisolated enum GlideDecoder {
    static let defaultBand = 4, defaultDirWeight = 0.0
    static func shapeCost(of word: String, _ g: ProcessedGlide, band: Int = defaultBand, dirWeight: Double = defaultDirWeight) -> Double? {
        KBNativeGlide.shapeCost(word.lowercased(), points: GlideBuffers.points(g.points), band: Int32(band), direction: dirWeight)?.doubleValue
    }
}
