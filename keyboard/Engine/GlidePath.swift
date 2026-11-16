import Foundation
import CoreGraphics

nonisolated struct GlideLayout {
	let centers: [(letter: Character, point: CGPoint)]
	let xPitch: CGFloat
	let yPitch: CGFloat
}

nonisolated struct ProcessedGlide {
	let points: [CGPoint]
	let pivots: [Int]
	let dwellKeys: [Character]
}

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
nonisolated enum GlideDecoder {
    static let defaultBand = 4, defaultDirWeight = 0.0
    static func shapeCost(of word: String, _ g: ProcessedGlide, band: Int = defaultBand, dirWeight: Double = defaultDirWeight) -> Double? {
        KBNativeGlide.shapeCost(word.lowercased(), points: GlideBuffers.points(g.points), band: Int32(band), direction: dirWeight)?.doubleValue
    }
}
