import XCTest
@testable import ShenSwift

final class ReaderTests: XCTestCase {
    private func read(_ s: String) -> [KLValue] {
        let interp = Interp()
        var r = Reader(s, intern: { interp.internValue($0) })
        return (try? r.readAll()) ?? []
    }

    func testNumbers() {
        if case .int(let n) = read("42")[0] { XCTAssertEqual(n, 42) } else { XCTFail() }
        if case .int(let n) = read("-7")[0] { XCTAssertEqual(n, -7) } else { XCTFail() }
        if case .double(let d) = read("3.5")[0] { XCTAssertEqual(d, 3.5) } else { XCTFail() }
    }

    func testSignsAreSymbols() {
        // Lone operators must stay symbols, never parse as numbers.
        for op in ["-", "+", ">", "<=", "/"] {
            if case .sym(let s) = read(op)[0] { XCTAssertEqual(s.name, op) }
            else { XCTFail("\(op) should be a symbol") }
        }
    }

    func testBooleans() {
        if case .bool(let b) = read("true")[0] { XCTAssertTrue(b) } else { XCTFail() }
        if case .bool(let b) = read("false")[0] { XCTAssertFalse(b) } else { XCTFail() }
    }

    func testStringWithNewline() {
        let v = read("\"a\nb\"")[0]
        if case .str(let s) = v { XCTAssertEqual(s, "a\nb") } else { XCTFail() }
    }

    func testNestedList() {
        let v = read("(a (b c) ())")[0]
        XCTAssertEqual(Printer.show(v), "(a (b c) ())")
    }
}

final class PrimitiveTests: XCTestCase {
    // Pure-primitive expressions evaluate without booting the kernel.
    private let interp = Interp()
    private func eval(_ s: String) throws -> KLValue { try interp.evalKL(s) }

    func testArithmetic() throws {
        XCTAssertEqual(Printer.show(try eval("(+ 1 2)")), "3")
        XCTAssertEqual(Printer.show(try eval("(* 6 7)")), "42")
        XCTAssertEqual(Printer.show(try eval("(- 10 3)")), "7")
        XCTAssertEqual(Printer.show(try eval("(/ 6 2)")), "3")     // exact -> int
        XCTAssertEqual(Printer.show(try eval("(/ 7 2)")), "3.5")   // inexact -> double
        XCTAssertEqual(Printer.show(try eval("(+ 1 2.5)")), "3.5")
    }

    func testComparisonsReturnBool() throws {
        XCTAssertEqual(Printer.show(try eval("(> 3 2)")), "true")
        XCTAssertEqual(Printer.show(try eval("(<= 2 2)")), "true")
        XCTAssertEqual(Printer.show(try eval("(< 3 2)")), "false")
    }

    func testListOps() throws {
        XCTAssertEqual(Printer.show(try eval("(hd (cons 1 (cons 2 ())))")), "1")
        XCTAssertEqual(Printer.show(try eval("(tl (cons 1 (cons 2 ())))")), "(2)")
        XCTAssertEqual(Printer.show(try eval("(cons? (cons 1 ()))")), "true")
        XCTAssertEqual(Printer.show(try eval("(cons? 1)")), "false")
    }

    func testEqualityNumericCoercion() throws {
        XCTAssertEqual(Printer.show(try eval("(= 2 2.0)")), "true")
        XCTAssertEqual(Printer.show(try eval("(= (cons 1 ()) (cons 1 ()))")), "true")
    }

    func testTailRecursionDoesNotOverflow() throws {
        // A self-tail-recursive KL countdown over a large range must not grow
        // the host stack thanks to the trampoline.
        _ = try eval("(defun count-down (N) (if (= N 0) done (count-down (- N 1))))")
        XCTAssertEqual(Printer.show(try eval("(count-down 500000)")), "done")
    }

    func testStrRejectsNonAtoms() throws {
        XCTAssertEqual(Printer.show(try eval("(str 42)")), "\"42\"")
        XCTAssertThrowsError(try eval("(str (cons 1 ()))"))
        XCTAssertThrowsError(try eval("(str (lambda X X))"))
    }
}

final class BootTests: XCTestCase {
    func testKernelBootsAndRunsShenLevelCode() throws {
        let interp = Interp()
        try interp.boot()
        // A kernel global established by initialise-environment.
        XCTAssertEqual(Printer.show(try interp.evalKL("(value *version*)")), "\"42\"")
        // A kernel-defined function (reverse) works end to end.
        XCTAssertEqual(Printer.show(try interp.evalKL("(reverse (cons 1 (cons 2 (cons 3 ()))))")),
                       "(3 2 1)")
    }
}

/// Ordering guarantees that only show up in the built CLI, when stdout is a pipe
/// (fully buffered) rather than a tty (line buffered).
final class CLIOutputOrderingTests: XCTestCase {
    /// Directory holding the built products (and hence the `shen-swift` binary).
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }

    /// `(load FILE)` must print each toplevel form's value as the form is
    /// evaluated and only then the `loaded` result — launcher output and kernel
    /// output share one buffer, so neither can jump the queue.
    func testLoadEchoesFormsBeforeLoadedMessage() throws {
        let binary = productsDirectory.appendingPathComponent("shen-swift")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "shen-swift executable not built")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shen-swift-load-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "\"PROBE\"\n(+ 40 2)\n".write(to: dir.appendingPathComponent("probe.shen"),
                                          atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["eval", "-e", "(load \"probe.shen\")"]
        proc.currentDirectoryURL = dir
        let pipe = Pipe()                       // a pipe, not a tty: full buffering
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let probe = lines.firstIndex(of: "\"PROBE\"")
        let answer = lines.firstIndex(of: "42")
        let loaded = lines.firstIndex(of: "loaded")
        XCTAssertNotNil(probe, "no per-form echo of \"PROBE\" in: \(lines)")
        XCTAssertNotNil(answer, "no per-form echo of 42 in: \(lines)")
        XCTAssertNotNil(loaded, "no `loaded` message in: \(lines)")
        if let probe, let answer, let loaded {
            XCTAssertLessThan(probe, answer, "toplevel forms echoed out of order: \(lines)")
            XCTAssertLessThan(answer, loaded, "`loaded` printed before the file's own output: \(lines)")
        }
    }
}
