import Foundation

/// The Shen/KLambda interpreter: symbol table, global state, evaluator, and the
/// kernel bootstrap. A single `Interp` instance is one live Shen image.
public final class Interp {
    // Symbol interner — one Sym per name.
    private var symbols: [String: Sym] = [:]

    // Cached special-form symbols (compared by identity in the eval loop).
    let sDefun, sLambda, sLet, sIf, sCond, sAnd, sOr, sDo, sFreeze, sThaw, sTrapError, sType: Sym

    // Standard streams.
    var stdoutStream: KLStream!
    var stdinStream: KLStream!

    /// Directory containing the kernel `.kl` files (resource bundle or override).
    public var klDirectory: URL?

    /// Directory containing the StLib `.shen` sources (resource bundle or override).
    public var stdlibDirectory: URL?

    public init() {
        var tbl: [String: Sym] = [:]
        func mk(_ n: String) -> Sym { let s = Sym(n); tbl[n] = s; return s }
        sDefun = mk("defun")
        sLambda = mk("lambda")
        sLet = mk("let")
        sIf = mk("if")
        sCond = mk("cond")
        sAnd = mk("and")
        sOr = mk("or")
        sDo = mk("do")
        sFreeze = mk("freeze")
        sThaw = mk("thaw")
        sTrapError = mk("trap-error")
        sType = mk("type")
        symbols = tbl

        setupStreams()
        registerPrimitives()
    }

    // MARK: - Interning

    func intern(_ name: String) -> Sym {
        if let s = symbols[name] { return s }
        let s = Sym(name)
        symbols[name] = s
        return s
    }

    /// Interns a token, mapping the reserved boolean names to `.bool`.
    func internValue(_ name: String) -> KLValue {
        switch name {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .sym(intern(name))
        }
    }

    // MARK: - Evaluation (trampolined for tail-call elimination)

    private enum Step {
        case done(KLValue)
        case tailCall(KLValue, Env?)
    }

    public func eval(_ expr0: KLValue, _ env0: Env?) throws -> KLValue {
        var expr = expr0
        var env = env0
        while true {
            switch expr {
            case .sym(let s):
                if let v = env?.lookup(s) { return v }
                return expr // self-evaluating global symbol

            case .cons(let c):
                // Gather argument expressions (unevaluated).
                let args = c.cdr.toArray() ?? []

                if case .sym(let h) = c.car {
                    // ---- Special forms ----
                    if h === sIf {
                        let t = try eval(args[0], env)
                        expr = t.isTrue ? args[1] : args[2]
                        continue
                    }
                    if h === sCond {
                        var matched = false
                        for clause in args {
                            guard let pair = clause.toArray(), pair.count == 2 else {
                                throw KLError("malformed cond clause")
                            }
                            if (try eval(pair[0], env)).isTrue {
                                expr = pair[1]; matched = true; break
                            }
                        }
                        if matched { continue }
                        throw KLError("cond: no condition was true")
                    }
                    if h === sLet {
                        let v = try eval(args[1], env)
                        guard case .sym(let vs) = args[0] else {
                            throw KLError("let: binding name must be a symbol")
                        }
                        env = Env(vs, v, env)
                        expr = args[2]
                        continue
                    }
                    if h === sLambda {
                        guard case .sym(let p) = args[0] else {
                            throw KLError("lambda: parameter must be a symbol")
                        }
                        return .fn(KLFunction(name: "", arity: 1, params: [p],
                                              body: args[1], closureEnv: env))
                    }
                    if h === sFreeze {
                        return .fn(KLFunction(name: "", arity: 0, params: [],
                                              body: args[0], closureEnv: env))
                    }
                    if h === sAnd {
                        if args.isEmpty { return .bool(true) }
                        var ok = true
                        for k in 0..<(args.count - 1) where !(try eval(args[k], env)).isTrue {
                            ok = false; break
                        }
                        if !ok { return .bool(false) }
                        expr = args[args.count - 1]
                        continue
                    }
                    if h === sOr {
                        if args.isEmpty { return .bool(false) }
                        var done = false
                        for k in 0..<(args.count - 1) where (try eval(args[k], env)).isTrue {
                            done = true; break
                        }
                        if done { return .bool(true) }
                        expr = args[args.count - 1]
                        continue
                    }
                    if h === sDo {
                        if args.isEmpty { return .empty }
                        for k in 0..<(args.count - 1) { _ = try eval(args[k], env) }
                        expr = args[args.count - 1]
                        continue
                    }
                    if h === sType {
                        expr = args[0] // ignore the type annotation
                        continue
                    }
                    if h === sDefun {
                        return try doDefun(args, env)
                    }
                    if h === sThaw {
                        let f = try eval(args[0], env)
                        switch try stepApply(f, []) {
                        case .done(let v): return v
                        case .tailCall(let b, let e): expr = b; env = e; continue
                        }
                    }
                    if h === sTrapError {
                        do {
                            return try eval(args[0], env)
                        } catch let e as KLError {
                            let handler = try eval(args[1], env)
                            return try apply(handler, [.error(e)])
                        }
                    }

                    // ---- Application with a symbolic operator ----
                    let fnVal: KLValue
                    if let v = env?.lookup(h) {
                        fnVal = v
                    } else if let f = h.fn {
                        fnVal = .fn(f)
                    } else {
                        throw KLError("undefined function \(h.name)")
                    }
                    let argVals = try args.map { try eval($0, env) }
                    switch try stepApply(fnVal, argVals) {
                    case .done(let v): return v
                    case .tailCall(let b, let e): expr = b; env = e; continue
                    }
                }

                // ---- Application with a compound operator, e.g. ((lambda ..) x) ----
                let fnVal = try eval(c.car, env)
                let argVals = try args.map { try eval($0, env) }
                switch try stepApply(fnVal, argVals) {
                case .done(let v): return v
                case .tailCall(let b, let e): expr = b; env = e; continue
                }

            default:
                return expr // numbers, strings, booleans, (), vectors, fns self-evaluate
            }
        }
    }

    private func doDefun(_ args: [KLValue], _ env: Env?) throws -> KLValue {
        guard args.count == 3, case .sym(let nameSym) = args[0],
              let paramList = args[1].toArray() else {
            throw KLError("malformed defun")
        }
        var params: [Sym] = []
        for p in paramList {
            guard case .sym(let ps) = p else { throw KLError("defun: parameters must be symbols") }
            params.append(ps)
        }
        nameSym.fn = KLFunction(name: nameSym.name, arity: params.count,
                                params: params, body: args[2], closureEnv: env)
        return .sym(nameSym)
    }

    /// One application step. Handles currying (under/over application) and
    /// returns a tail continuation for interpreted functions so the main loop
    /// can eliminate tail calls.
    private func stepApply(_ fnVal: KLValue, _ args: [KLValue]) throws -> Step {
        guard case .fn(let f) = fnVal else {
            if args.isEmpty { return .done(fnVal) }
            throw KLError("cannot apply a non-function: \(Printer.show(fnVal))")
        }
        let need = f.arity - f.captured.count
        if args.count < need {
            return .done(.fn(f.partial(args)))
        }
        let now = f.captured + Array(args[0..<need])
        let rest = Array(args[need...])
        if let prim = f.prim {
            let result = try prim(now)
            if rest.isEmpty { return .done(result) }
            return try stepApply(result, rest)
        } else {
            let newEnv = extend(f.params, now, f.closureEnv)
            if rest.isEmpty {
                return .tailCall(f.body!, newEnv)
            }
            let result = try eval(f.body!, newEnv)
            return try stepApply(result, rest)
        }
    }

    /// Full (non-tail) application.
    @discardableResult
    func apply(_ fnVal: KLValue, _ args: [KLValue]) throws -> KLValue {
        switch try stepApply(fnVal, args) {
        case .done(let v): return v
        case .tailCall(let body, let env): return try eval(body, env)
        }
    }

    // MARK: - Convenience for primitives & boot

    func setGlobal(_ name: String, _ value: KLValue) {
        intern(name).gv = value
    }

    func defPrim(_ name: String, _ arity: Int, _ body: @escaping ([KLValue]) throws -> KLValue) {
        intern(name).fn = KLFunction(name: name, arity: arity, prim: body)
    }
}
