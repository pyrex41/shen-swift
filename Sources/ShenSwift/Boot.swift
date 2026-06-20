import Foundation

extension Interp {
    /// Canonical kernel load order for ShenOSKernel 41.x (matches shen-go),
    /// followed by the extension files that provide the standard CLI launcher
    /// (`shen.x.launcher.main`: eval / script / repl / --version / --help).
    static let kernelFiles = [
        "toplevel", "core", "sys", "sequent", "yacc",
        "reader", "prolog", "track", "load", "writer",
        "macros", "declarations", "t-star", "types",
        "dict", "init",
        "extension-features", "extension-expand-dynamic", "extension-launcher",
    ]

    /// Resolves the directory holding the kernel `.kl` files.
    func resolveKLDirectory() throws -> URL {
        if let dir = klDirectory { return dir }
        if let url = Bundle.module.url(forResource: "klambda", withExtension: nil) {
            return url
        }
        throw KLError("cannot locate the bundled klambda kernel directory")
    }

    /// Loads and evaluates every form in one `.kl` file.
    func loadKLFile(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var reader = Reader(text, intern: { [unowned self] in self.internValue($0) })
        let forms = try reader.readAll()
        for form in forms {
            _ = try eval(form, nil)
        }
    }

    /// Sets the port-identity and I/O globals the kernel expects.
    func installGlobals() {
        setGlobal("*stinput*", .stream(stdinStream))
        setGlobal("*stoutput*", .stream(stdoutStream))
        setGlobal("*sterror*", .stream(stdoutStream))
        setGlobal("*home-directory*", .str(FileManager.default.currentDirectoryPath))
        setGlobal("*language*", .str("Swift"))
        setGlobal("*implementation*", .str("Apple Swift"))
        let v = "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        setGlobal("*release*", .str(v))
        setGlobal("*os*", .str("macOS"))
        setGlobal("*port*", .str("0.1.0"))
        setGlobal("*porters*", .str("Reuben Brooks"))
        // All other globals (*hush*, *version*, shen.*tc*, the property vector,
        // *macros*, the arity table, ...) are established by the kernel's own
        // (shen.initialise-environment), invoked at the end of boot().
    }

    /// Boots the full Shen kernel. Call once before evaluating user code.
    public func boot(verbose: Bool = false) throws {
        let dir = try resolveKLDirectory()
        installGlobals()
        for name in Interp.kernelFiles {
            let url = dir.appendingPathComponent("\(name).kl")
            if verbose { FileHandle.standardError.write(Data("loading \(name).kl\n".utf8)) }
            try loadKLFile(url)
        }
        // Replace kernel functions that rely on machinery our direct-defun boot
        // bypasses (notably `fn`, which the kernel resolves via stored
        // lambda-forms in the property vector — we resolve straight from the
        // symbol's function slot, which already curries).
        installNativeOverrides()

        // Establish the runtime environment. (shen.initialise) runs all three
        // sub-initialisers: environment (globals, property vector, arity table,
        // macros, prolog memory), lambda-forms, and signed-funcs (type
        // signatures, i.e. shen.*sigf*). The kernel defines these but leaves it
        // to the port to invoke.
        if verbose { FileHandle.standardError.write(Data("initialising environment\n".utf8)) }
        _ = try eval(.list([.sym(intern("shen.initialise"))]), nil)
    }

    /// Native replacements for kernel functions whose default implementation
    /// depends on bootstrap bookkeeping we don't reproduce.
    func installNativeOverrides() {
        // `(fn f)` turns a function name into an applicable value. The kernel
        // looks this up in the property-vector lambda-form table (populated by
        // build-lambda-table at install). We return the symbol's function slot
        // directly; partial application is handled by the evaluator's currying.
        defPrim("fn", 1) { [weak self] a in
            guard case .sym(let s) = a[0] else {
                throw KLError("fn: argument is not a symbol: \(Printer.show(a[0]))")
            }
            guard let f = s.fn else { throw KLError("fn: \(s.name) is undefined") }
            // The kernel's `fn` immediately invokes nullary functions.
            if f.arity == 0 { return try self!.apply(.fn(f), []) }
            return .fn(f)
        }

        // `(pr String Stream)` — write a string to a stream. The kernel's pr
        // silences output for EVERY stream when *hush* is true; we instead gate
        // only the standard output, so explicit file streams still write under
        // -q (matches shen-go/shen-julia/shen-scheme, and lets shen-swift host
        // ratatoskr shakes, which run under -q). Writing bytes directly also
        // sidesteps the kernel's per-character write path.
        let hushSym = intern("*hush*")
        defPrim("pr", 2) { [weak self] a in
            let s = (try? Printer.str(a[0])) ?? Printer.show(a[0])
            guard case .stream(let stream) = a[1], let write = stream.writeByte else {
                throw KLError("pr: second argument is not an output stream")
            }
            let hush = hushSym.gv?.isTrue ?? false
            if hush && stream === self!.stdoutStream {
                return a[0] // silenced stdout under *hush*
            }
            for byte in s.utf8 { write(Int(byte)) }
            return a[0]
        }
    }

    /// Loads only the top-level `defun` forms of a `.kl` file (evaluating each)
    /// and returns the file's remaining non-defun top-level forms unevaluated,
    /// so a caller can run them AFTER `(shen.initialise)`. Forms are identified
    /// by a proper parse (the Reader), so `defun` bodies that embed literal
    /// newlines inside string constants are still classified correctly.
    func loadDefunsCollectingTops(_ url: URL) throws -> [KLValue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var reader = Reader(text, intern: { [unowned self] in self.internValue($0) })
        let forms = try reader.readAll()
        var tops: [KLValue] = []
        for form in forms {
            if case .cons(let c) = form, case .sym(let s) = c.car, s.name == "defun" {
                _ = try eval(form, nil)
            } else {
                tops.append(form)
            }
        }
        return tops
    }

    /// Boots from a Ratatoskr-shaken slice — a minimal `kernel.kl` (just the
    /// defuns the program transitively needs) plus the user `.kl` — instead of
    /// the full 19-file kernel. The load order mirrors the Scheme/Lua stage-2
    /// builders: all defuns first, then the native overrides, then
    /// `(shen.initialise)`, then the collected top-level forms (kernel, then
    /// user) so the program's effects run against a fully initialised
    /// environment. The user `.kl`'s top-level forms ARE the program, so no
    /// launcher is invoked — boot runs to the program's natural completion.
    public func bootShaken(kernel: URL, user: URL, verbose: Bool = false) throws {
        installGlobals()
        if verbose { FileHandle.standardError.write(Data("loading shaken kernel \(kernel.lastPathComponent)\n".utf8)) }
        let kTops = try loadDefunsCollectingTops(kernel)
        if verbose { FileHandle.standardError.write(Data("loading user \(user.lastPathComponent)\n".utf8)) }
        let uTops = try loadDefunsCollectingTops(user)
        installNativeOverrides()
        if verbose { FileHandle.standardError.write(Data("initialising environment\n".utf8)) }
        _ = try eval(.list([.sym(intern("shen.initialise"))]), nil)
        for form in kTops { _ = try eval(form, nil) }
        for form in uTops { _ = try eval(form, nil) }
    }

    /// Starts the interactive Shen read-eval-print loop (`(shen.repl)`).
    public func runREPL() throws {
        _ = try eval(.list([.sym(intern("shen.repl"))]), nil)
    }

    /// Drives the kernel's standard CLI launcher with `args`, where `args[0]`
    /// is the program name and the rest are the command and its arguments
    /// (`eval -e <expr>`, `script <file>`, `repl`, `--version`, `--help`, or
    /// nothing for an interactive REPL). This is the same entry point shen-go,
    /// shen-rust, shen-julia and ShenScript expose, so the CLI surface matches.
    public func runLauncher(_ args: [String]) throws {
        let argv = KLValue.list(args.map { .str($0) })
        guard let launcher = intern("shen.x.launcher.main").fn else {
            throw KLError("launcher not loaded: shen.x.launcher.main is undefined")
        }
        // Apply the function directly to the argv *value* so it is not
        // re-evaluated as a code expression.
        _ = try apply(.fn(launcher), [argv])
    }

    /// Evaluates a single already-parsed KLambda form at top level.
    @discardableResult
    public func evalKL(_ source: String) throws -> KLValue {
        var reader = Reader(source, intern: { [unowned self] in self.internValue($0) })
        let forms = try reader.readAll()
        var result: KLValue = .empty
        for f in forms { result = try eval(f, nil) }
        return result
    }
}
