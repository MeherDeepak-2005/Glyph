import Foundation

/// The dynamic vocabulary layers (the user's adopted words, the platform's supplementary
/// words): a native mutable trie the shared engine reads through KBGenerationLexicon.
/// Callers serialize mutation (Lexicon's lock).
nonisolated final class Trie {
	let native = KBMutableTrie()
	func insert(_ word: String, freq: Int) {
		native.insertWord(word, frequency: Int64(freq), wordID: -1)
	}
	func contains(_ word: String) -> Bool { native.containsWord(word) }
}
