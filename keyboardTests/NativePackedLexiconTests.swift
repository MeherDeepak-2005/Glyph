import Foundation
import Testing
@testable import keyboard

struct NativePackedLexiconTests {
    private func minimalV7(version: UInt32 = 7) -> Data {
        var bytes = Data()
        func put(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        func node(label: UInt8, children: UInt8, first: UInt32, id: UInt32, maxFrequency: UInt32) {
            bytes.append(label); bytes.append(children); put(first); put(id); put(maxFrequency)
        }
        for value: UInt32 in [0x4B424C4D, version, 1, 2] { put(value) }
        put(19)
        put(0); put(1)
        node(label: 0, children: 1, first: 1, id: 0xFFFF_FFFF, maxFrequency: 19)
        node(label: UInt8(ascii: "x"), children: 0, first: 0, id: 0, maxFrequency: 19)
        bytes.append(UInt8(ascii: "x"))
        return bytes
    }

    @Test func coreV4StoredFormsHaveWideTrieIDs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin")))
        for word in ["accommodative", "acetylcholine", "café", "naïve", "wi-fi"] {
            let id = try #require(reader.trieWordID(word))
            #expect(reader.word(Int(id)) == word)
            #expect(reader.freq(Int(id)) >= 1)
        }
        #expect(try #require(reader.trieWordID("accommodative")) > 65_535)
        for excluded in ["cant", "im", "lets", "wont"] {
            #expect(reader.trieWordID(excluded) == nil)
        }
    }

    @Test func bridgeAcceptsOnlyImmutableCompleteV7Backing() throws {
        let bytes = minimalV7()
        let bridge = try KBPackedLexicon(backing: NSData(data: bytes))
        #expect(bridge.formatVersion == 7)
        #expect(bridge.wordCount == 1)
        #expect(throws: (any Error).self) {
            try KBPackedLexicon(backing: NSMutableData(data: bytes))
        }
        #expect(throws: (any Error).self) {
            try KBPackedLexicon(backing: NSData(data: bytes.prefix(17)))
        }
        #expect(throws: (any Error).self) {
            try KBPackedLexicon(backing: NSData(data: minimalV7(version: 6)))
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kblm-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(LangData(url: url))
        #expect(reader.wordCount == 1)
        #expect(reader.trieContains("x"))
        #expect(!reader.trieContains("xx"))
        #expect(reader.word(0) == "x")
        #expect(reader.freq(0) == 19)
        #expect(reader.trieChildren(after: "").map(\.label) == [UInt8(ascii: "x")])
        #expect(reader.trieChildren(after: "").map(\.maxFreq) == [19])
        let truncated = FileManager.default.temporaryDirectory.appendingPathComponent("kblm-\(UUID().uuidString).bin")
        try bytes.prefix(bytes.count - 1).write(to: truncated)
        defer { try? FileManager.default.removeItem(at: truncated) }
        #expect(LangData(url: truncated) == nil)
    }
}
