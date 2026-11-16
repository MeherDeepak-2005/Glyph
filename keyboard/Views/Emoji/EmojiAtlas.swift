import UIKit
import Darwin

final class EmojiAtlas {
	nonisolated static let pointSize: CGFloat = 47
	private nonisolated static let glyphFraction: CGFloat = 28.0 / 36.0
	nonisolated static let glyphFontSize: CGFloat = pointSize * glyphFraction
	nonisolated static let cellPitch: CGFloat = 60
	nonisolated static let compactPointSize: CGFloat = 36
	nonisolated static let compactGlyphFontSize: CGFloat = 28

	let count: Int
	private let tilePx: Int
	private let displayScale: CGFloat
	private let strip: CGImage
	private let indexOf: [String: Int]

	private init?(url: URL, tilePx: Int, count: Int, store: EmojiStore) {
		guard tilePx > 0, count > 0,
			  let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
			  fileSize == count * tilePx * tilePx * 4,
			  let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let provider = Self.mappedProvider(url: url, size: fileSize),
			  let strip = CGImage(width: tilePx, height: tilePx * count,
								  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tilePx * 4,
								  space: space,
								  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
								  provider: provider, decode: nil, shouldInterpolate: true,
								  intent: .defaultIntent)
		else { return nil }
		var map: [String: Int] = [:]
		map.reserveCapacity(count)
		var i = 0
		for c in 0..<store.categoryCount {
			for item in 0..<store.emojiCount(c) {
				map[store.emoji(c, item)] = i
				i += 1
			}
		}
		guard i == count else { return nil }
		self.tilePx = tilePx
		self.count = count
		self.displayScale = CGFloat(tilePx) / Self.pointSize
		self.strip = strip
		self.indexOf = map
	}

	private nonisolated static func mappedProvider(url: URL, size: Int) -> CGDataProvider? {
		guard size > 0 else { return nil }
		let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
			guard let path else { return -1 }
			return open(path, O_RDONLY)
		}
		guard descriptor >= 0 else { return nil }
		defer { close(descriptor) }
		guard let mapping = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
			mapping != MAP_FAILED else { return nil }
		guard let provider = CGDataProvider(dataInfo: nil, data: mapping, size: size,
			releaseData: { _, data, length in
				munmap(UnsafeMutableRawPointer(mutating: data), length)
			}) else {
			munmap(mapping, size)
			return nil
		}
		return provider
	}

	func image(for emoji: String) -> UIImage? {
		guard let i = indexOf[emoji],
			  let tile = strip.cropping(to: CGRect(x: 0, y: CGFloat(i * tilePx),
												   width: CGFloat(tilePx), height: CGFloat(tilePx)))
		else { return nil }
		return UIImage(cgImage: tile, scale: displayScale, orientation: .up)
	}

	private nonisolated static func containerURL() -> URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
	}
	private nonisolated static func fileName(tilePx: Int, count: Int,
		fingerprint: UInt64) -> String {
		let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
		return String(format: "emoji_atlas_v2_%016llx_t%d_n%d_os%d.bin",
			fingerprint, tilePx, count, os)
	}
	private nonisolated static func totalEmoji(in store: EmojiStore) -> Int {
		(0..<store.categoryCount).reduce(0) { $0 + store.emojiCount($1) }
	}
	private nonisolated static func tilePx(for scale: CGFloat) -> Int {
		Int((pointSize * max(scale, 1)).rounded())
	}

	static func load(store: EmojiStore?, scale: CGFloat, in dir: URL? = nil) -> EmojiAtlas? {
		guard let store, let dir = dir ?? containerURL() else { return nil }
		let tile = tilePx(for: scale)
		let count = totalEmoji(in: store)
		let url = dir.appendingPathComponent(fileName(tilePx: tile, count: count,
			fingerprint: store.catalogFingerprint))
		return EmojiAtlas(url: url, tilePx: tile, count: count, store: store)
	}

	private static var _shared: EmojiAtlas?
	private static var sharedIdentity: (fingerprint: UInt64, tilePx: Int)?
	static func loadShared(store: EmojiStore?, scale: CGFloat) -> EmojiAtlas? {
		guard let store else { return nil }
		let identity = (store.catalogFingerprint, tilePx(for: scale))
		if let a = _shared, let sharedIdentity,
			sharedIdentity.fingerprint == identity.0,
			sharedIdentity.tilePx == identity.1 { return a }
		_shared = load(store: store, scale: scale)
		sharedIdentity = _shared == nil ? nil : identity
		return _shared
	}

	static func purgeShared() {
		_shared = nil
		sharedIdentity = nil
	}

	@discardableResult
	nonisolated static func generateIfNeeded(store: EmojiStore? = EmojiStore.bundled,
										 scale: CGFloat, in dir: URL? = nil) -> URL? {
		guard let store, let dir = dir ?? containerURL() else { return nil }
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let tile = tilePx(for: scale)
		let count = totalEmoji(in: store)
		guard count > 0 else { return nil }
		let url = dir.appendingPathComponent(fileName(tilePx: tile, count: count,
			fingerprint: store.catalogFingerprint))
		if FileManager.default.fileExists(atPath: url.path) { return url }

		if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
			for f in entries where f.lastPathComponent.hasPrefix("emoji_atlas_") {
				try? FileManager.default.removeItem(at: f)
			}
		}

		let tmp = dir.appendingPathComponent(".emoji_atlas_\(UUID().uuidString).tmp")
		guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { return nil }
		defer { try? FileManager.default.removeItem(at: tmp) }
		guard let handle = try? FileHandle(forWritingTo: tmp) else { return nil }
		let ok = rasterize(store, tilePx: tile, to: handle)
		try? handle.close()
		guard ok else { return nil }
		if FileManager.default.fileExists(atPath: url.path) { return url }
		guard (try? FileManager.default.moveItem(at: tmp, to: url)) != nil else { return nil }
		return url
	}

	private nonisolated static func rasterize(_ store: EmojiStore, tilePx tile: Int, to handle: FileHandle) -> Bool {
		var buf = [UInt8](repeating: 0, count: tile * tile * 4)
		return buf.withUnsafeMutableBytes { raw -> Bool in
			guard let base = raw.baseAddress,
				  let space = CGColorSpace(name: CGColorSpace.sRGB),
				  let ctx = CGContext(data: base, width: tile, height: tile,
									  bitsPerComponent: 8, bytesPerRow: tile * 4, space: space,
									  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
			else { return false }
			ctx.translateBy(x: 0, y: CGFloat(tile))
			ctx.scaleBy(x: 1, y: -1)
			UIGraphicsPushContext(ctx)
			defer { UIGraphicsPopContext() }

			let T = CGFloat(tile)
			var failed = false
			for c in 0..<store.categoryCount {
				for item in 0..<store.emojiCount(c) where !failed {
					autoreleasepool {
						ctx.clear(CGRect(x: 0, y: 0, width: T, height: T))
						var font = UIFont.systemFont(ofSize: T * glyphFraction)
						var str = NSAttributedString(string: store.emoji(c, item), attributes: [.font: font])
						var sz = str.size()
						if sz.width > T || sz.height > T {
							font = font.withSize(font.pointSize * min(T / sz.width, T / sz.height))
							str = NSAttributedString(string: store.emoji(c, item), attributes: [.font: font])
							sz = str.size()
						}
						str.draw(at: CGPoint(x: (T - sz.width) / 2, y: (T - sz.height) / 2))
						do { try handle.write(contentsOf: Data(bytes: base, count: raw.count)) }
						catch { failed = true }
					}
				}
			}
			return !failed
		}
	}
}
