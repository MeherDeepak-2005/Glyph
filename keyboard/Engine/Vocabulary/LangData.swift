// LangData: the memory-mapped English dictionary, langdata.bin (KBLM v7, built by
// tools/build_language_data.py; layout in native/DecoderCore/include/PackedLexicon.hpp):
// unigram frequencies and the spelling trie. The native reader (KBPackedLexicon) validates
// it and shares the one mapping; Swift reads the trie in place for lookups and key priors.
import Foundation

nonisolated final class LangData {
	let data: Data
	/// The native reader over the same immutable mapping; the shared engine decodes with it.
	let nativeCandidateLexicon: KBPackedLexicon
	let wordCount: Int
	private let trieNodeCount: Int
	private let freqBase, offsBase, trieBase, blobBase: Int
	private static let headerSize = 16, trieNodeSize = 14
	static let empty = 0xFFFFFFFF          // a trie node without a word

	init?(url: URL) {
		// One immutable backing shared by Swift and native readers, kept alive by both.
		// Data(referencing:) avoids a second mapped allocation. The native reader rejects
		// anything but a valid v7 dictionary.
		guard let backing = try? NSData(contentsOf: url, options: .alwaysMapped),
			let reader = try? KBPackedLexicon(backing: backing) else { return nil }
		// Spelling policies for modern vocabulary ride beside the dictionary; a missing or
		// mismatched sidecar is refused natively and decoding runs without them.
		if let sidecar = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("kbmodern")),
		   !reader.installModernData(sidecar) {
			KBDiagnostics.recorder.storageFailure(operation: "kbmodern-load")
		}
		let d = Data(referencing: backing)
		data = d
		nativeCandidateLexicon = reader
		wordCount = Int(reader.wordCount)
		trieNodeCount = Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }))
		freqBase = Self.headerSize
		offsBase = freqBase + 4 * wordCount
		trieBase = offsBase + 4 * (wordCount + 1)
		blobBase = trieBase + Self.trieNodeSize * trieNodeCount
	}

	private func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}
	func freq(_ id: Int) -> Int { u32(freqBase + 4 * id) }
	func word(_ id: Int) -> String {
		let a = blobBase + u32(offsBase + 4 * id), b = blobBase + u32(offsBase + 4 * (id + 1))
		return String(decoding: data[a..<b], as: UTF8.self)
	}

	// MARK: The trie, read in place: BFS order, node 0 the root, each node's children
	// contiguous and label-sorted (label u8, childCount u8, firstChild u32, wordID u32,
	// maxFreq u32).

	private func nodeByte(_ node: Int, _ off: Int) -> Int {
		Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + Self.trieNodeSize * node + off, as: UInt8.self) })
	}
	private func nodeU32(_ node: Int, _ off: Int) -> UInt32 {
		UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + Self.trieNodeSize * node + off, as: UInt32.self) })
	}

	/// Walk the exact byte path from the root; nil when it leaves the trie.
	private func trieNode(for word: [UInt8]) -> Int? {
		guard trieNodeCount > 0 else { return nil }
		var idx = 0
		for ch in word {
			let first = Int(nodeU32(idx, 2))
			let count = nodeByte(idx, 1)
			var next = -1
			for c in 0..<count where nodeByte(first + c, 0) == Int(ch) { next = first + c; break }
			guard next >= 0 else { return nil }
			idx = next
		}
		return idx
	}

	func trieContains(_ lw: String) -> Bool { trieWordID(lw) != nil }

	func trieWordID(_ lw: String) -> Int32? {
		guard let n = trieNode(for: Array(lw.utf8)) else { return nil }
		let id = nodeU32(n, 6)
		return id == UInt32(Self.empty) ? nil : Int32(bitPattern: id)
	}

	/// Children (label byte, subtree max frequency) of the node at `prefix` — the
	/// next-character distribution that key-target resizing feeds on. Empty prefix =
	/// root = word-initial letters. A handful of clean-page reads, nothing more.
	func trieChildren(after prefix: String) -> [(label: UInt8, maxFreq: UInt32)] {
		guard let n = trieNode(for: Array(prefix.utf8)) else { return [] }
		let first = Int(nodeU32(n, 2)), count = nodeByte(n, 1)
		return (0..<count).map { (UInt8(nodeByte(first + $0, 0)), nodeU32(first + $0, 10)) }
	}
}
