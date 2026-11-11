// Glide contracts the controller and the engine exchange.
import Foundation

nonisolated struct GlidePrediction {
	let word: String
	let alternatives: [String]
	let shapeCostByWord: [String: Double]
	let margin: Double
}

nonisolated struct GlideSessionID: Hashable, Sendable {
	let rawValue: UInt64
}

nonisolated struct GlideUpdate {
	let sessionID: GlideSessionID
	let revision: UInt64
	let prediction: GlidePrediction
}
