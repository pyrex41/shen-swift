import Foundation

// MARK: - Symbol (interned)

/// An interned Shen/KLambda symbol. Identity (`===`) is meaningful because the
/// interner guarantees one `Sym` instance per name. Symbols carry their own
/// function- and global-value slots so that `(value s)` / `(set s v)` and
/// function calls avoid dictionary lookups.
public final class Sym {
    public let name: String
    /// Function namespace (populated by `defun`).
    var fn: KLFunction?
    /// Global value namespace (populated by `set`).
    var gv: KLValue?

    init(_ name: String) { self.name = name }
}

// MARK: - Cons cell

public final class Cons {
    var car: KLValue
    var cdr: KLValue
    init(_ car: KLValue, _ cdr: KLValue) {
        self.car = car
        self.cdr = cdr
    }
}

// MARK: - Absvector

public final class KLVector {
    var items: [KLValue]
    init(count: Int, fill: KLValue) {
        items = Array(repeating: fill, count: count)
    }
}

// MARK: - Error object (carried through `trap-error`)

public final class KLError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - Functions (primitives, lambdas, defuns, partial applications)

public final class KLFunction {
    let name: String
    let arity: Int
    /// Native primitive implementation (mutually exclusive with `body`).
    let prim: (([KLValue]) throws -> KLValue)?
    /// Interpreted-function parameters.
    let params: [Sym]
    /// Interpreted-function body.
    let body: KLValue?
    /// Lexical environment captured at closure creation.
    let closureEnv: Env?
    /// Already-supplied arguments (currying / partial application).
    let captured: [KLValue]

    init(name: String, arity: Int,
         prim: (([KLValue]) throws -> KLValue)? = nil,
         params: [Sym] = [],
         body: KLValue? = nil,
         closureEnv: Env? = nil,
         captured: [KLValue] = []) {
        self.name = name
        self.arity = arity
        self.prim = prim
        self.params = params
        self.body = body
        self.closureEnv = closureEnv
        self.captured = captured
    }

    func partial(_ extra: [KLValue]) -> KLFunction {
        KLFunction(name: name, arity: arity, prim: prim, params: params,
                   body: body, closureEnv: closureEnv, captured: captured + extra)
    }
}

// MARK: - Streams

public final class KLStream {
    enum Direction { case input, output }
    let direction: Direction
    /// Returns the next byte (0-255), or -1 at EOF.
    var readByte: (() -> Int)?
    /// Writes one byte.
    var writeByte: ((Int) -> Void)?
    /// Optional close hook.
    var onClose: (() -> Void)?
    var closed = false

    init(direction: Direction) { self.direction = direction }
}

// MARK: - The universal value type

public enum KLValue {
    case sym(Sym)
    case str(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case empty                 // the empty list ()
    case cons(Cons)
    case fn(KLFunction)
    case vector(KLVector)
    case stream(KLStream)
    case error(KLError)
}

// MARK: - Convenience constructors / helpers

extension KLValue {
    static func list(_ elems: [KLValue]) -> KLValue {
        var acc: KLValue = .empty
        for e in elems.reversed() { acc = .cons(Cons(e, acc)) }
        return acc
    }

    /// Collects a proper list into an array. Returns nil if improper.
    func toArray() -> [KLValue]? {
        var out: [KLValue] = []
        var cur = self
        while true {
            switch cur {
            case .empty: return out
            case .cons(let c): out.append(c.car); cur = c.cdr
            default: return nil
            }
        }
    }

    var isTrue: Bool {
        if case .bool(let b) = self { return b }
        return false
    }

    var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
}

// MARK: - Equality (`=` primitive semantics)

func klEquals(_ a: KLValue, _ b: KLValue) -> Bool {
    switch (a, b) {
    case (.sym(let x), .sym(let y)): return x === y
    case (.str(let x), .str(let y)): return x == y
    case (.bool(let x), .bool(let y)): return x == y
    case (.empty, .empty): return true
    case (.int(let x), .int(let y)): return x == y
    case (.double(let x), .double(let y)): return x == y
    case (.int(let x), .double(let y)): return Double(x) == y
    case (.double(let x), .int(let y)): return x == Double(y)
    case (.cons(let x), .cons(let y)):
        return klEquals(x.car, y.car) && klEquals(x.cdr, y.cdr)
    case (.vector(let x), .vector(let y)):
        if x === y { return true }
        if x.items.count != y.items.count { return false }
        for i in 0..<x.items.count where !klEquals(x.items[i], y.items[i]) { return false }
        return true
    case (.fn(let x), .fn(let y)): return x === y
    case (.stream(let x), .stream(let y)): return x === y
    case (.error(let x), .error(let y)): return x === y
    default: return false
    }
}

// MARK: - Lexical environment (single-binding frames, cons-style)

public final class Env {
    let sym: Sym
    let val: KLValue
    let parent: Env?
    init(_ sym: Sym, _ val: KLValue, _ parent: Env?) {
        self.sym = sym
        self.val = val
        self.parent = parent
    }

    func lookup(_ s: Sym) -> KLValue? {
        var e: Env? = self
        while let cur = e {
            if cur.sym === s { return cur.val }
            e = cur.parent
        }
        return nil
    }
}

func extend(_ params: [Sym], _ vals: [KLValue], _ parent: Env?) -> Env? {
    var e = parent
    for i in 0..<params.count { e = Env(params[i], vals[i], e) }
    return e
}
