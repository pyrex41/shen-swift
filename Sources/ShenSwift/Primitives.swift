import Foundation

extension Interp {
    // MARK: - Standard streams

    func setupStreams() {
        let out = KLStream(direction: .output)
        out.writeByte = { byte in putchar(Int32(byte & 0xff)) }
        stdoutStream = out

        let inp = KLStream(direction: .input)
        // End of standard input. The 42.1+ reader (shen.read-loop) parses a
        // final line that has no trailing newline when read-byte reports -1, so
        // if bytes are pending on the current line we return -1 once. EOF at a
        // line boundary (or a second EOF) exits cleanly instead: the kernel REPL
        // would otherwise loop forever on "empty stream" errors.
        var pendingLine = false
        inp.readByte = {
            fflush(stdout)         // make sure any prompt is visible first
            let c = getchar()      // buffered; returns EOF (-1) at end of input
            if c == -1 {
                if pendingLine {
                    pendingLine = false
                    return -1
                }
                putchar(10)
                fflush(stdout)
                exit(0)
            }
            pendingLine = (c != 10)
            return Int(c)
        }
        stdinStream = inp
    }

    // MARK: - Primitive registration

    func registerPrimitives() {
        // ---- Lists ----
        defPrim("cons", 2) { a in .cons(Cons(a[0], a[1])) }
        defPrim("hd", 1) { a in
            guard case .cons(let c) = a[0] else { throw KLError("hd: not a cons cell: \(Printer.show(a[0]))") }
            return c.car
        }
        defPrim("tl", 1) { a in
            guard case .cons(let c) = a[0] else { throw KLError("tl: not a cons cell: \(Printer.show(a[0]))") }
            return c.cdr
        }
        defPrim("cons?", 1) { a in
            if case .cons = a[0] { return .bool(true) }
            return .bool(false)
        }

        // ---- Equality ----
        defPrim("=", 2) { a in .bool(klEquals(a[0], a[1])) }

        // ---- Arithmetic ----
        defPrim("+", 2) { a in try Interp.arith(a[0], a[1], "+") }
        defPrim("-", 2) { a in try Interp.arith(a[0], a[1], "-") }
        defPrim("*", 2) { a in try Interp.arith(a[0], a[1], "*") }
        defPrim("/", 2) { a in try Interp.arith(a[0], a[1], "/") }
        defPrim(">", 2) { a in .bool(try Interp.cmp(a[0], a[1]) > 0) }
        defPrim("<", 2) { a in .bool(try Interp.cmp(a[0], a[1]) < 0) }
        defPrim(">=", 2) { a in .bool(try Interp.cmp(a[0], a[1]) >= 0) }
        defPrim("<=", 2) { a in .bool(try Interp.cmp(a[0], a[1]) <= 0) }
        defPrim("number?", 1) { a in
            switch a[0] { case .int, .double: return .bool(true); default: return .bool(false) }
        }

        // ---- Strings ----
        defPrim("string?", 1) { a in
            if case .str = a[0] { return .bool(true) }; return .bool(false)
        }
        defPrim("str", 1) { a in .str(try Printer.str(a[0])) }
        defPrim("pos", 2) { a in
            guard case .str(let s) = a[0] else { throw KLError("pos: not a string") }
            guard case .int(let n) = a[1] else { throw KLError("pos: not an integer index") }
            let chars = Array(s)
            guard n >= 0 && n < chars.count else { throw KLError("pos: index \(n) out of range") }
            return .str(String(chars[n]))
        }
        defPrim("tlstr", 1) { a in
            guard case .str(let s) = a[0] else { throw KLError("tlstr: not a string") }
            guard !s.isEmpty else { throw KLError("tlstr: empty string") }
            return .str(String(s.dropFirst()))
        }
        defPrim("cn", 2) { a in
            guard case .str(let x) = a[0], case .str(let y) = a[1] else {
                throw KLError("cn: arguments must be strings")
            }
            return .str(x + y)
        }
        defPrim("string->n", 1) { a in
            guard case .str(let s) = a[0], let first = s.unicodeScalars.first else {
                throw KLError("string->n: empty or non-string")
            }
            return .int(Int(first.value))
        }
        defPrim("n->string", 1) { a in
            guard case .int(let n) = a[0], let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: n)) else {
                throw KLError("n->string: invalid code point")
            }
            return .str(String(scalar))
        }

        // ---- Symbols & globals ----
        defPrim("intern", 1) { [weak self] a in
            guard case .str(let s) = a[0] else { throw KLError("intern: not a string") }
            return self!.internValue(s)
        }
        defPrim("value", 1) { a in
            guard case .sym(let s) = a[0] else { throw KLError("value: not a symbol: \(Printer.show(a[0]))") }
            guard let v = s.gv else { throw KLError("the variable \(s.name) is unbound") }
            return v
        }
        defPrim("set", 2) { a in
            guard case .sym(let s) = a[0] else { throw KLError("set: not a symbol: \(Printer.show(a[0]))") }
            s.gv = a[1]
            return a[1]
        }

        // ---- Errors ----
        defPrim("simple-error", 1) { a in
            let msg = (try? Printer.str(a[0])) ?? Printer.show(a[0])
            throw KLError(msg)
        }
        defPrim("error-to-string", 1) { a in
            guard case .error(let e) = a[0] else {
                throw KLError("error-to-string: not an error object")
            }
            return .str(e.message)
        }

        // ---- Eval ----
        defPrim("eval-kl", 1) { [weak self] a in try self!.eval(a[0], nil) }

        // ---- Vectors (absvectors) ----
        let failSym = intern("fail!")
        defPrim("absvector", 1) { a in
            guard case .int(let n) = a[0], n >= 0 else { throw KLError("absvector: bad size") }
            return .vector(KLVector(count: n, fill: .sym(failSym)))
        }
        defPrim("<-address", 2) { a in
            guard case .vector(let v) = a[0] else { throw KLError("<-address: not a vector") }
            guard case .int(let n) = a[1], n >= 0, n < v.items.count else {
                throw KLError("<-address: index out of range")
            }
            return v.items[n]
        }
        defPrim("address->", 3) { a in
            guard case .vector(let v) = a[0] else { throw KLError("address->: not a vector") }
            guard case .int(let n) = a[1], n >= 0, n < v.items.count else {
                throw KLError("address->: index out of range")
            }
            v.items[n] = a[2]
            return a[0]
        }
        defPrim("absvector?", 1) { a in
            if case .vector = a[0] { return .bool(true) }; return .bool(false)
        }

        // ---- I/O ----
        defPrim("write-byte", 2) { a in
            guard case .int(let b) = a[0] else { throw KLError("write-byte: not a byte") }
            guard case .stream(let s) = a[1], let w = s.writeByte else {
                throw KLError("write-byte: not an output stream")
            }
            w(b)
            return a[0]
        }
        defPrim("read-byte", 1) { a in
            guard case .stream(let s) = a[0], let r = s.readByte else {
                throw KLError("read-byte: not an input stream")
            }
            return .int(r())
        }
        defPrim("open", 2) { [weak self] a in try self!.openFile(a) }
        defPrim("close", 1) { a in
            if case .stream(let s) = a[0] { s.onClose?(); s.closed = true }
            return .empty
        }

        // ---- Public character-stream interfaces (ShenOSKernel 43.1) ----
        // Swift exposes byte-oriented streams.  43.1 still requires these
        // public callables to exist so the kernel can install their arities,
        // callable forms, and type signatures during initialization.
        defPrim("char-stream?", 1) { a in
            guard case .stream = a[0] else {
                throw KLError("char-stream? expects a stream")
            }
            return .bool(false)
        }
        defPrim("read-unit-string", 1) { a in
            guard case .stream(let s) = a[0], s.direction == .input,
                  let read = s.readByte else {
                throw KLError("read-unit-string requires open input stream")
            }
            let byte = read()
            guard byte >= 0 else { throw KLError("read-unit-string: end of stream") }
            return .str(String(UnicodeScalar(byte & 0xff)!))
        }
        defPrim("write-string", 2) { a in
            guard case .str(let text) = a[0] else {
                throw KLError("write-string requires a string")
            }
            guard case .stream(let s) = a[1], s.direction == .output,
                  let write = s.writeByte else {
                throw KLError("write-string requires open output stream")
            }
            for byte in text.utf8 { write(Int(byte)) }
            return a[0]
        }

        // ---- Time ----
        defPrim("get-time", 1) { a in
            var kind = "real"
            if case .sym(let s) = a[0] { kind = s.name }
            switch kind {
            case "run":
                return .double(Double(clock()) / Double(CLOCKS_PER_SEC))
            case "unix":
                return .int(Int(Date().timeIntervalSince1970))
            default: // "real"
                return .double(Date().timeIntervalSince1970)
            }
        }
    }

    // MARK: - Helpers

    private func openFile(_ a: [KLValue]) throws -> KLValue {
        guard case .str(let path) = a[0] else { throw KLError("open: path must be a string") }
        var dir = "in"
        if case .sym(let s) = a[1] { dir = s.name }
        if dir == "in" || dir == "input" {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw KLError("open: cannot read file \(path)")
            }
            let bytes = [UInt8](data)
            var idx = 0
            let s = KLStream(direction: .input)
            s.readByte = {
                if idx < bytes.count { let b = Int(bytes[idx]); idx += 1; return b }
                return -1
            }
            return .stream(s)
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: path) else {
                throw KLError("open: cannot create file \(path)")
            }
            let s = KLStream(direction: .output)
            s.writeByte = { b in fh.write(Data([UInt8(b & 0xff)])) }
            s.onClose = { try? fh.close() }
            return .stream(s)
        }
    }

    static func arith(_ a: KLValue, _ b: KLValue, _ op: String) throws -> KLValue {
        if case .int(let x) = a, case .int(let y) = b {
            switch op {
            case "+":
                let (r, o) = x.addingReportingOverflow(y)
                return o ? .double(Double(x) + Double(y)) : .int(r)
            case "-":
                let (r, o) = x.subtractingReportingOverflow(y)
                return o ? .double(Double(x) - Double(y)) : .int(r)
            case "*":
                let (r, o) = x.multipliedReportingOverflow(by: y)
                return o ? .double(Double(x) * Double(y)) : .int(r)
            default: // "/"
                if y == 0 { throw KLError("division by zero") }
                if x % y == 0 { return .int(x / y) }
                return .double(Double(x) / Double(y))
            }
        }
        guard let x = a.asDouble, let y = b.asDouble else {
            throw KLError("arithmetic on non-numbers: \(Printer.show(a)) \(Printer.show(b))")
        }
        switch op {
        case "+": return .double(x + y)
        case "-": return .double(x - y)
        case "*": return .double(x * y)
        default:
            if y == 0 { throw KLError("division by zero") }
            return .double(x / y)
        }
    }

    static func cmp(_ a: KLValue, _ b: KLValue) throws -> Int {
        guard let x = a.asDouble, let y = b.asDouble else {
            throw KLError("comparison on non-numbers: \(Printer.show(a)) \(Printer.show(b))")
        }
        if x < y { return -1 }
        if x > y { return 1 }
        return 0
    }
}
