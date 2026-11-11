import Foundation

/// Numeric buffers consumed synchronously by the Objective-C++ bridge. Missing
/// tap rows and missing individual taps retain distinct existing Swift semantics.
nonisolated struct NativeTapBuffers {
    let offsets: Data
    let validity: Data
    init?(taps: [KeyTap?]?, expectedCount: Int) {
        guard let taps, taps.count == expectedCount else { return nil }
        var offsets = Data()
        var validity = Data()
        offsets.reserveCapacity(taps.count * 2 * MemoryLayout<Double>.size)
        validity.reserveCapacity(taps.count)
        for tap in taps {
            var dx = tap?.dx ?? 0, dy = tap?.dy ?? 0
            withUnsafeBytes(of: &dx) { offsets.append(contentsOf: $0) }
            withUnsafeBytes(of: &dy) { offsets.append(contentsOf: $0) }
            validity.append(tap == nil ? 0 : 1)
        }
        self.offsets = offsets
        self.validity = validity
    }
}
