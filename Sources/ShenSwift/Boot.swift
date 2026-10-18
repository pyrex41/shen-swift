import Foundation

extension Interp {
    /// The 16 runtime kernel modules of the community ShenOSKernel-43.1 release
    /// (shen-sources tag `shen-43.1` — see klambda/PROVENANCE.md). Every file
    /// holds only `defun`s, so their order is not significant; all runtime
    /// state (globals, the `*property-vector*` shen.dict, the arity table, the
    /// lambda forms, the type signatures) is established afterwards by
    /// `(shen.initialise)` from init.kl. dict.kl provides the hash-table
    /// property store that 42.x uses in place of a raw property vector.
    ///
    /// The release also ships `stlib.kl` (the precompiled standard library,
    /// loaded by `loadStdlib`) and the community `extension-*.kl` files. Those
    /// are vendored byte-for-byte but not booted: the CLI launcher is provided
    /// natively by `runLauncher`, matching the extension's command surface.
    static let kernelFiles = [
        "sys", "writer", "core", "reader", "declarations", "toplevel", "macros",
        "load", "prolog", "sequent", "track", "t-star", "yacc", "types", "dict",
        "init",
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
    /// ShenOSKernel 43.1 boot sequence (doc/porting.md, shen-scheme 0.51):
    /// load every module's defuns, install the host overrides, then call
    /// `(shen.initialise)`, which builds the shen.dict property store, the
    /// arity and lambda-form tables, the macro and source-form-handler
    /// registries and the kernel's type signatures, and sets `*version*` to
    /// "43.1". Unlike the refreshed S41.2 kernel this port used to vendor,
    /// there are no top-level forms to sequence.
    ///
    /// When `stdlib` is true, the precompiled standard library (`stlib.kl`) is
    /// loaded afterwards and `(stlib.initialise)` is called (see `loadStdlib`).
    public func boot(verbose: Bool = false, stdlib: Bool = false) throws {
        let dir = try resolveKLDirectory()
        installGlobals()

        for name in Interp.kernelFiles {
            let url = dir.appendingPathComponent("\(name).kl")
            if verbose { FileHandle.standardError.write(Data("loading \(name).kl\n".utf8)) }
            try loadKLFile(url)
        }

        // Host overrides go in before initialisation, so the kernel's own
        // set-up runs against them (cf. shen-c / shen-scheme).
        installNativeOverrides()

        if verbose { FileHandle.standardError.write(Data("calling shen.initialise\n".utf8)) }
        _ = try eval(.list([.sym(intern("shen.initialise"))]), nil)

        // shen.initialise only sets *home-directory* / *sterror* when they are
        // unbound, so the port-identity globals survive; re-assert them anyway
        // so the launcher always reports this host.
        installGlobals()

        if stdlib { try loadStdlib(verbose: verbose) }
    }

    /// Loads the precompiled standard library shipped with ShenOSKernel-43.1
    /// (`klambda/stlib.kl`) on top of an already-booted kernel, then calls
    /// `(stlib.initialise)` to install its package information, arities,
    /// lambda forms, macros, synonyms, datatypes and types (doc/port-upgrades.md,
    /// 41.1). This replaces the S41.2-era approach of compiling Tarver's
    /// `Lib/StLib` Shen sources at load time (~25 s in this interpreter).
    ///
    /// It stays opt-in (`--stdlib` / `boot(stdlib:)`), as before, so a plain
    /// kernel boot stays as fast as possible for the iOS target.
    public func loadStdlib(verbose: Bool = false) throws {
        let dir = try resolveKLDirectory()
        if verbose { FileHandle.standardError.write(Data("loading stlib.kl\n".utf8)) }
        try loadKLFile(dir.appendingPathComponent("stlib.kl"))
        if verbose { FileHandle.standardError.write(Data("calling stlib.initialise\n".utf8)) }
        _ = try eval(.list([.sym(intern("stlib.initialise"))]), nil)
    }

    /// Native replacements for kernel functions.
    ///
    /// 42.2 audit: no native here reads or writes the property store
    /// (`get`/`put`/`unput`), the arity table, `fn` or lambda forms — those all
    /// run the kernel's own 42.2 code against its shen.dict, so redefinitions
    /// (including the 42.0 arity-1 -> arity-0 lambda-form invalidation) are
    /// observed by `(fn F)`. The S41.2-era native `fn` (which read the symbol's
    /// function slot) was removed. The port does not override the reader,
    /// `macroexpand` or `shen.macroexpand-h`, so the 42.1 source-form handler
    /// order is the kernel's.
    func installNativeOverrides() {
        // `(hash X Bound)` — 42.x keeps the property store, the arity table and
        // the lambda forms in a portable shen.dict whose every access hashes the
        // key. The kernel's hash explodes the key's printed form and multiplies
        // character codes in Shen, which in this tree-walker roughly tripled the
        // kernel test-suite time. doc/port-performance.md ("Hashing") permits a
        // host structural hash consistent with `=`: equal values (1 / 1.0,
        // true / (intern "true"), structurally equal lists and vectors) hash
        // equal. It is a deterministic FNV-1a (no per-process seed), and keeps
        // the kernel's result range (0 maps to 1, so 1..Bound-1, or 1 when
        // Bound = 1). Non-integer or non-positive bounds defer to the kernel's
        // own definition, so its errors are unchanged.
        if let kernelHash = intern("hash").fn {
            defPrim("hash", 2) { [weak self] a in
                guard case .int(let bound) = a[1], bound > 0 else {
                    return try self!.apply(.fn(kernelHash), a)
                }
                var h = FNV()
                Interp.structuralHash(a[0], into: &h, depth: 0)
                let r = Int(h.value % UInt64(bound))
                return .int(r == 0 ? 1 : r)
            }
        }

        // `(pr String Stream)` — write a string to a stream. The kernel's pr
        // silences output for EVERY stream when *hush* is true; we instead gate
        // only the standard output, so explicit file streams still write under
        // -q (matches shen-go/shen-julia/shen-scheme, and lets shen-swift host
        // yggdrasil shakes, which run under -q). Writing bytes directly also
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

    /// Boots from a Yggdrasil-shaken slice — a minimal `kernel.kl` (just the
    /// defuns the program transitively needs) plus the user `.kl` — instead of
    /// the full kernel. The load order mirrors the Scheme/Lua stage-2 builders
    /// and the full `boot()`: all defuns first, then the native overrides,
    /// then `(shen.initialise)` when the slice defines it (42.2 slices carry
    /// init.kl's initialiser; slices from the refreshed S41.2 kernel instead
    /// initialise through top-level forms), then the collected top-level forms
    /// (kernel, then user) so the program's effects run against a fully
    /// initialised environment. The user `.kl`'s top-level forms ARE the
    /// program, so no launcher is invoked — boot runs to natural completion.
    public func bootShaken(kernel: URL, user: URL, verbose: Bool = false) throws {
        installGlobals()
        if verbose { FileHandle.standardError.write(Data("loading shaken kernel \(kernel.lastPathComponent)\n".utf8)) }
        let kTops = try loadDefunsCollectingTops(kernel)
        if verbose { FileHandle.standardError.write(Data("loading user \(user.lastPathComponent)\n".utf8)) }
        let uTops = try loadDefunsCollectingTops(user)
        installNativeOverrides()
        if verbose { FileHandle.standardError.write(Data("initialising environment\n".utf8)) }
        if intern("shen.initialise").fn != nil {
            _ = try eval(.list([.sym(intern("shen.initialise"))]), nil)
        }
        for form in kTops { _ = try eval(form, nil) }
        for form in uTops { _ = try eval(form, nil) }
    }

    /// Starts the interactive Shen read-eval-print loop: the 42.2 kernel's
    /// `shen.repl` (credits banner + `shen.loop`).
    public func runREPL() throws {
        _ = try eval(.list([.sym(intern("shen.repl"))]), nil)
    }

    /// CLI launcher, `args[0]` being the program name and the rest the command
    /// and its arguments (`eval …`, `script <file> …`, `repl`, `--version`,
    /// `--help`, or nothing for an interactive REPL). Mirrors the command
    /// surface shen-go / shen-rust / shen-julia / ShenScript expose.
    ///
    /// This is a native re-implementation of the community
    /// `extension-launcher.kl` (`shen.x.launcher.main`, vendored but not booted)
    /// driving the kernel's own `eval`, `read-from-string`, `load` and
    /// `shen.app`.
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
                // Printed through `pr` on the standard output, as
                // extension-launcher.kl does, so `-q` (*hush*) silences it.
                _ = try apply(fn("pr"), [out, .stream(stdoutStream)])
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

    /// Writes a launcher message to standard output.
    ///
    /// This MUST go through C stdio's `stdout` — the same `FILE *` the kernel's
    /// `*stoutput*` stream writes to (`putchar`, see `setupStreams`). Writing via
    /// `FileHandle.standardOutput` instead issues a raw `write(2)` straight to the
    /// file descriptor, overtaking whatever the kernel has left sitting in stdio's
    /// buffer: when stdout is a pipe (fully buffered, unlike a line-buffered tty)
    /// that reorders launcher output ahead of the interpreter's own. The visible
    /// symptom was `(load "f.shen")` printing `loaded` *before* the per-form echoes
    /// `load` itself had already printed (bifrost `load-toplevel-echo`).
    private func writeStdout(_ s: String) {
        let bytes = Array(s.utf8)
        if !bytes.isEmpty { fwrite(bytes, 1, bytes.count, stdout) }
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

/// 64-bit FNV-1a, used by the native `hash` override (deterministic across
/// runs, unlike Swift's seeded `Hasher`).
struct FNV {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func byte(_ b: UInt8) {
        value = (value ^ UInt64(b)) &* 0x0000_0100_0000_01b3
    }

    mutating func word(_ w: UInt64) {
        var w = w
        for _ in 0..<8 { byte(UInt8(truncatingIfNeeded: w)); w >>= 8 }
    }

    mutating func string(_ s: String) {
        for b in s.utf8 { byte(b) }
        byte(0xff) // terminator, so ("ab" "c") and ("a" "bc") differ
    }
}

extension Interp {
    /// Feeds a structural hash of `v` into `h`, consistent with `klEquals`:
    /// values that are `=` produce the same byte stream. Lists and vectors are
    /// hashed over a bounded prefix and depth, which keeps that property (equal
    /// values share every prefix) while bounding work on large or cyclic data.
    static func structuralHash(_ v: KLValue, into h: inout FNV, depth: Int) {
        if depth > 8 { h.byte(0x00); return }
        switch v {
        case .sym(let s):
            h.byte(0x01); h.string(s.name)
        case .bool(let b):
            // `true`/`false` are booleans here even when interned from strings.
            h.byte(0x01); h.string(b ? "true" : "false")
        case .str(let s):
            h.byte(0x02); h.string(s)
        case .int(let n):
            h.byte(0x03); h.word(UInt64(bitPattern: Int64(n)))
        case .double(let d):
            // 1 = 1.0, so an integral double hashes as the integer.
            if d == d.rounded(), let n = Int64(exactly: d) {
                h.byte(0x03); h.word(UInt64(bitPattern: n))
            } else {
                h.byte(0x04); h.word(d == 0 ? 0 : d.bitPattern)
            }
        case .empty:
            h.byte(0x05)
        case .cons:
            h.byte(0x06)
            var cur = v
            var n = 0
            while case .cons(let c) = cur, n < 32 {
                structuralHash(c.car, into: &h, depth: depth + 1)
                cur = c.cdr
                n += 1
            }
            if n < 32 { structuralHash(cur, into: &h, depth: depth + 1) }
        case .vector(let vec):
            h.byte(0x07)
            h.word(UInt64(vec.items.count))
            for item in vec.items.prefix(16) { structuralHash(item, into: &h, depth: depth + 1) }
        case .fn(let f):
            h.byte(0x08); h.word(UInt64(UInt(bitPattern: ObjectIdentifier(f).hashValue)))
        case .stream(let s):
            h.byte(0x09); h.word(UInt64(UInt(bitPattern: ObjectIdentifier(s).hashValue)))
        case .error(let e):
            h.byte(0x0a); h.word(UInt64(UInt(bitPattern: ObjectIdentifier(e).hashValue)))
        }
    }
}
