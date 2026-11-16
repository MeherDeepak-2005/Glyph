import Foundation

nonisolated final class Trie {
	let native = KBMutableTrie()
	func insert(_ word: String, freq: Int) {
		native.insertWord(word, frequency: Int64(freq), wordID: -1)
	}
	func contains(_ word: String) -> Bool { native.containsWord(word) }
}
