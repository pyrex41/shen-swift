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
        XCTAssertEqual(Printer.show(try interp.evalKL("(value *version*)")), "\"41.2\"")
        // A kernel-defined function (reverse) works end to end.
        XCTAssertEqual(Printer.show(try interp.evalKL("(reverse (cons 1 (cons 2 (cons 3 ()))))")),
                       "(3 2 1)")
    }
}
