import UIKit
import XCTest

@_silgen_name("kb_ios_bench")
private func kbIOSBench(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

final class DeviceBenchmark: XCTestCase {
	@MainActor func testReplayPushedCorpora() throws {
		let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("bench")
		let input = root.appendingPathComponent("in"), output = root.appendingPathComponent("out")
		let names = (try? FileManager.default.contentsOfDirectory(atPath: input.path)) ?? []
		let corpora = names.filter { $0.hasSuffix(".tsv") }.sorted()
		try XCTSkipIf(corpora.isEmpty, "no corpora in \(input.path)")
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		let pushedModel = input.appendingPathComponent("nss-english.nsslm")
		let model = FileManager.default.fileExists(atPath: pushedModel.path) ? pushedModel
			: try XCTUnwrap(Bundle.main.builtInPlugInsURL?
				.appendingPathComponent("demo_keyboard.appex/nss-english.nsslm"))
		XCTAssertTrue(FileManager.default.fileExists(atPath: model.path), "no NSS model at \(model.path)")
		setenv("KB_NSS", model.path, 1)
		UIApplication.shared.isIdleTimerDisabled = true
		defer { UIApplication.shared.isIdleTimerDisabled = false }
		let done = expectation(description: "replay")
		var failures: [String] = []
		Thread.detachNewThread {
			for corpus in corpora {
				let result = output.appendingPathComponent(corpus.replacingOccurrences(of: ".tsv", with: ".jsonl"))
				let args = ["bench", input.appendingPathComponent("langdata.bin").path,
					input.appendingPathComponent("safety.kbguard").path,
					input.appendingPathComponent(corpus).path, result.path]
				var argv = args.map { strdup($0) } + [nil]
				let started = Date()
				if kbIOSBench(Int32(args.count), &argv) != 0 { failures.append(corpus) }
				argv.forEach { free($0) }
				print("device-bench \(corpus) \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
			}
			done.fulfill()
		}
		wait(for: [done], timeout: 3_600)
		XCTAssertEqual(failures, [])
	}
}
