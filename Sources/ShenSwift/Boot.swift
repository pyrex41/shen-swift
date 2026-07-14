import Foundation

extension Interp {
    /// The 15 KLambda files of Mark Tarver's refreshed S41.2 kernel (mirror
    /// pyrex41/shen-s41.1 @ tag s41.2-pristine-20260711 — see klambda/PROVENANCE.md),
    /// in the order given by the upstream Sources/make.shen. That is the
    /// *bootstrap* (compile .shen -> .kl) order; the fresh-runtime load below is
    /// two-phase, so the only ordering constraint it actually imposes is that
    /// each file's defuns are interned before any top-level form runs.
    ///
    /// This kernel has no `shen.initialise`, no bundled `stlib.kl`, and no
    /// community `extension-*.kl` launcher — initialisation happens through
    /// top-level forms in declarations.kl and types.kl (see `boot()`), the
    /// standard library ships separately as lazy Shen sources (Lib/StLib, not
    /// vendored here), and the CLI is provided natively by `runLauncher`.
    static let kernelFiles = [
        "yacc", "core", "load", "prolog", "reader", "sequent", "sys", "t-star",
        "toplevel", "track", "types", "writer", "backend", "declarations", "macros",
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
        // top-level forms in declarations.kl, run during boot()'s second phase.
    }

    /// Boots the full Shen kernel. Call once before evaluating user code.
    ///
    /// Two-phase load. The refreshed S41.2 kernel has no `shen.initialise`;
    /// instead the runtime is initialised by *top-level* forms: declarations.kl
    /// establishes the globals (`*property-vector*`, `shen.*sigf*`, `*version*`,
    /// …), the arity table and the lambda table, and types.kl declares the
    /// kernel's ~160 type signatures. Those declares read globals that
    /// declarations.kl sets, but Sources/make.shen lists types.kl *before*
    /// declarations.kl (correct for compiling .shen, wrong for loading compiled
    /// .kl into a fresh image). So we intern every file's defuns first, then run
    /// the collected top-level forms with declarations.kl ahead of types.kl.
    public func boot(verbose: Bool = false) throws {
        let dir = try resolveKLDirectory()
        installGlobals()

        // Phase 1 — intern all defuns; collect the non-defun top-level forms.
        var tops: [String: [KLValue]] = [:]
        for name in Interp.kernelFiles {
            let url = dir.appendingPathComponent("\(name).kl")
            if verbose { FileHandle.standardError.write(Data("loading \(name).kl\n".utf8)) }
            tops[name] = try loadDefunsCollectingTops(url)
        }

        // Replace kernel functions that rely on machinery our direct-defun boot
        // bypasses (notably `fn`, which the kernel resolves via stored
        // lambda-forms in the property vector — we resolve straight from the
        // symbol's function slot, which already curries).
        installNativeOverrides()

        // Phase 2 — run the top-level forms. declarations.kl first (it sets the
        // globals types.kl's declares depend on), then the rest in load order.
        let topOrder = ["declarations"] + Interp.kernelFiles.filter { $0 != "declarations" }
        for name in topOrder {
            guard let forms = tops[name], !forms.isEmpty else { continue }
            if verbose { FileHandle.standardError.write(Data("initialising from \(name).kl\n".utf8)) }
            for form in forms { _ = try eval(form, nil) }
        }

        // Re-assert the port-identity globals the kernel overwrites while
        // loading (declarations.kl sets *home-directory* to "").
        installGlobals()
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
    /// so a caller can run them after every defun is interned (see `boot()` and
    /// `bootShaken`). Forms are identified by a proper parse (the Reader), so
    /// `defun` bodies that embed literal newlines inside string constants are
    /// still classified correctly.
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
    /// the full 15-file kernel. The load order mirrors the Scheme/Lua stage-2
    /// builders: all defuns first, then the native overrides, then (for pre-S41.2
    /// slices only) `(shen.initialise)`, then the collected top-level forms
    /// (kernel, then user) so the program's effects run against a fully
    /// initialised environment. The user `.kl`'s top-level forms ARE the
    /// program, so no launcher is invoked — boot runs to natural completion.
    ///
    /// NOTE: slices shaken from the refreshed S41.2 kernel carry their own
    /// initialisation in `kTops` (no `shen.initialise`); they must be
    /// regenerated by the Ratatoskr shaker and re-checked with `bifrost --shake`.
    public func bootShaken(kernel: URL, user: URL, verbose: Bool = false) throws {
        installGlobals()
        if verbose { FileHandle.standardError.write(Data("loading shaken kernel \(kernel.lastPathComponent)\n".utf8)) }
        let kTops = try loadDefunsCollectingTops(kernel)
        if verbose { FileHandle.standardError.write(Data("loading user \(user.lastPathComponent)\n".utf8)) }
        let uTops = try loadDefunsCollectingTops(user)
        installNativeOverrides()
        // Pre-S41.2 shaken slices bundled a `shen.initialise`; the refreshed
        // kernel initialises through its top-level forms (carried in kTops)
        // instead, so only call it when the slice actually defines it.
        if verbose { FileHandle.standardError.write(Data("initialising environment\n".utf8)) }
        if intern("shen.initialise").fn != nil {
            _ = try eval(.list([.sym(intern("shen.initialise"))]), nil)
        }
        for form in kTops { _ = try eval(form, nil) }
        for form in uTops { _ = try eval(form, nil) }
    }

    /// Starts the interactive Shen read-eval-print loop. The refreshed S41.2
    /// kernel's entry point is `shen.shen` (banner + `shen.loop`); it replaces
    /// the `shen.repl` of the community kernel.
    public func runREPL() throws {
        _ = try eval(.list([.sym(intern("shen.shen"))]), nil)
    }

    /// CLI launcher, `args[0]` being the program name and the rest the command
    /// and its arguments (`eval …`, `script <file> …`, `repl`, `--version`,
    /// `--help`, or nothing for an interactive REPL). Mirrors the command
    /// surface shen-go / shen-rust / shen-julia / ShenScript expose.
    ///
    /// The community `extension-launcher.kl` that formerly supplied
    /// `shen.x.launcher.main` is not part of Tarver's refreshed S41.2 kernel, so
    /// this is a native re-implementation driving the kernel's own `eval`,
    /// `read-from-string`, `load` and `shen.app`.
    public func runLauncher(_ args: [String]) throws {
        let rest = Array(args.dropFirst()) // drop program name
        let prog = args.first ?? "shen-swift"

        guard let cmd = rest.first else { try runREPL(); return }
        switch cmd {
        case "repl":
            try runREPL()
        case "--version":
            writeStdout(try versionString() + "\n")
        case "--help":
            writeStdout(helpText(prog) + "\n")
        case "script":
            guard rest.count >= 2 else { throw KLError("script: missing FILE argument") }
            let file = rest[1]
            setGlobal("*argv*", .list(Array(rest[1...]).map { .str($0) }))
            // quiet-load: read the file and evaluate each form.
            let forms = try apply(fn("read-file"), [.str(file)])
            for form in forms.toArray() ?? [] { _ = try apply(fn("eval"), [form]) }
        case "eval":
            try runEval(Array(rest.dropFirst()))
        default:
            throw KLError("unknown command: \(cmd) (try `\(prog) --help')")
        }
    }

    /// `eval` sub-command: evaluate `-e/--eval <EXPR>`, `-l/--load <FILE>`,
    /// `-q/--quiet`, `-r/--repl` left to right.
    private func runEval(_ args: [String]) throws {
        var i = 0
        var launchREPL = false
        while i < args.count {
            switch args[i] {
            case "-e", "--eval":
                guard i + 1 < args.count else { throw KLError("eval: \(args[i]) needs an expression") }
                let result = try evalUserString(args[i + 1])
                let out = try apply(fn("shen.app"), [result, .str("\n"), .sym(intern("shen.a"))])
                if case .str(let s) = out { writeStdout(s) }
                i += 2
            case "-l", "--load":
                guard i + 1 < args.count else { throw KLError("eval: \(args[i]) needs a file") }
                _ = try apply(fn("load"), [.str(args[i + 1])])
                i += 2
            case "-q", "--quiet":
                setGlobal("*hush*", .bool(true))
                i += 1
            case "-r", "--repl":
                launchREPL = true
                i += 1
            default:
                throw KLError("eval: invalid argument: \(args[i])")
            }
        }
        if launchREPL { try runREPL() }
    }

    /// Reads and evaluates one expression from a string: `(eval (head
    /// (read-from-string EXPR)))`, built as a value so EXPR needs no escaping.
    func evalUserString(_ expr: String) throws -> KLValue {
        let form = KLValue.list([
            .sym(intern("eval")),
            .list([.sym(intern("head")),
                   .list([.sym(intern("read-from-string")), .str(expr)])]),
        ])
        return try eval(form, nil)
    }

    /// Resolves a kernel function by name (for launcher plumbing).
    private func fn(_ name: String) throws -> KLValue {
        guard let f = intern(name).fn else { throw KLError("\(name) is undefined") }
        return .fn(f)
    }

    private func writeStdout(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    private func globalString(_ name: String) -> String {
        if case .str(let s) = intern(name).gv { return s }
        return ""
    }

    private func versionString() throws -> String {
        let version = globalString("*version*")
        let language = globalString("*language*")
        let port = globalString("*port*")
        let implementation = globalString("*implementation*")
        let release = globalString("*release*")
        return "\(version) (port (\"\(language)\" \"\(port)\") implementation (\"\(implementation)\" \"\(release)\"))"
    }

    private func helpText(_ prog: String) -> String {
        """
        Usage: \(prog) [--version] [--help] <COMMAND> [<ARGS>]

        commands:
            repl
                Launches the interactive REPL.
                Default action if no command is supplied.

            script <FILE> [<ARGS>]
                Runs the script in FILE. *argv* is set to [FILE | ARGS].

            eval <ARGS>
                Evaluates expressions and files, left to right:
                    -e, --eval <EXPR>   Evaluate EXPR and print the result.
                    -l, --load <FILE>   Read and evaluate FILE.
                    -q, --quiet         Silence interactive output (*hush*).
                    -r, --repl          Launch the REPL after evaluating.
        """
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
