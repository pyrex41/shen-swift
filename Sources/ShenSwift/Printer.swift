import Foundation

enum Printer {
    /// Formats a number the way Shen does: integers without a point, floats with.
    static func numberString(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d)) + ".0"
        }
        return String(d)
    }

    /// Implements the `str` primitive: convert an atom to its string form.
    /// Only atoms (symbols, strings, numbers, booleans) are convertible; every
    /// other value throws, which the kernel relies on (e.g. `symbol?` calls
    /// `str` inside a `trap-error` to reject closures, lists, and vectors).
    static func str(_ v: KLValue) throws -> String {
        switch v {
        case .sym(let s): return s.name
        case .str(let s): return s
        case .int(let n): return String(n)
        case .double(let d): return numberString(d)
        case .bool(let b): return b ? "true" : "false"
        case .empty: throw KLError("str: () is not an atom")
        case .stream: throw KLError("str: a stream is not an atom")
        case .fn: throw KLError("str: a function is not an atom")
        case .cons: throw KLError("str: a list is not an atom")
        case .vector: throw KLError("str: a vector is not an atom")
        case .error: throw KLError("str: an exception is not an atom")
        }
    }

    /// A general, debugging-oriented printer for whole values (lists included).
    static func show(_ v: KLValue) -> String {
        switch v {
        case .sym(let s): return s.name
        case .str(let s): return "\"\(s)\""
        case .int(let n): return String(n)
        case .double(let d): return numberString(d)
        case .bool(let b): return b ? "true" : "false"
        case .empty: return "()"
        case .stream: return "<stream>"
        case .fn(let f): return "<function \(f.name)>"
        case .error(let e): return "<error \(e.message)>"
        case .vector(let vec):
            return "<vector " + vec.items.map(show).joined(separator: " ") + ">"
        case .cons:
            var parts: [String] = []
            var cur = v
            while case .cons(let c) = cur {
                parts.append(show(c.car))
                cur = c.cdr
            }
            if case .empty = cur {
                return "(" + parts.joined(separator: " ") + ")"
            }
            return "(" + parts.joined(separator: " ") + " . " + show(cur) + ")"
        }
    }
}
