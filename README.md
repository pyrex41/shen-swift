# shen-swift

A from-scratch port of the [Shen programming language](https://shenlanguage.org)
to Swift, designed to run on macOS **and iOS**.

It is a **tree-walking KLambda interpreter**: it loads Mark Tarver's refreshed
**S41.2** `.kl` sources at runtime and interprets them (the 15 files are vendored
verbatim under `Sources/ShenSwift/klambda/` — see its `PROVENANCE.md`). Because
nothing is compiled or code-generated on device, it runs inside the iOS sandbox
(no JIT, no `dlopen`, no runtime `swiftc`), and supports live `(define ...)` at
the REPL.

> **Kernel note.** Upstream reused the version string "41.2" for a *restructured*
> kernel (different lineage from the community `ShenOSKernel-41.2` this port used
> before). It drops `init.kl`/`dict.kl`/`stlib.kl` and the community
> `extension-*.kl`, and adds a `cl.*` Common-Lisp backend (`backend.kl`, inert
> here). There is no longer a `shen.initialise`: the runtime is set up by
> top-level forms in `declarations.kl` and `types.kl`, so `boot()` loads in two
> phases (intern every defun, then run the top-level forms with declarations
> ahead of types). See `PROVENANCE.md` for the full delta.

## Architecture

```
.kl kernel sources ──Reader──▶ [KLValue AST]
                                     │
                          Interp.eval()   ← trampolined for tail-call elimination
                                     │
                          46 KLambda primitives  (cons/hd/tl, +-*/, absvector,
                                                   intern/value/set, str/pos/cn,
                                                   read-byte/write-byte/open/close, …)
```

| File | Responsibility |
|------|----------------|
| `Value.swift` | `KLValue`, interned `Sym`, `Cons`, `KLVector`, `KLStream`, `KLFunction`, `Env`, equality |
| `Reader.swift` | KLambda S-expression tokenizer + parser |
| `Interp.swift` | Trampolined evaluator, special forms, currying/partial application |
| `Primitives.swift` | The ~46 KLambda primitives + standard streams |
| `Printer.swift` | `str` and value formatting |
| `Boot.swift` | Two-phase kernel load, environment init, native overrides, native CLI launcher, public API |
| `klambda/` | Bundled refreshed S41.2 `.kl` sources (resource) — see `klambda/PROVENANCE.md` |

### Key design points

- **Tail-call elimination.** `eval` is a `while` loop; tail positions
  (`if`/`cond`/`let`/`and`/`or`/`do` branches and saturated function
  application) rebind the current expression/environment instead of recursing.
- **Currying.** Functions carry already-supplied arguments; under-application
  returns a partial closure, over-application applies the result to the rest.
- **Native overrides.** A direct-`defun` boot bypasses the kernel's
  property-vector lambda-form table, so `fn` (named higher-order references) is
  replaced with a native version that returns the symbol's function slot.
- **Deep recursion.** The CLI runs the interpreter on a 512 MB-stack thread so
  non-tail user recursion (e.g. the recursive arm of `append`) does not overflow.

## Build & run

```sh
swift build -c release
swift run -c release shen-swift            # interactive REPL
echo '(+ 1 2)' | swift run -c release shen-swift
```

Flags: `--verbose` (boot diagnostics), `--kl <dir>` (override the kernel
directory), `--shaken <kernel.kl> <user.kl>` (Ratatoskr stage-2 mode: boot a
minimal shaken slice and run the user program to completion instead of loading
the full kernel + launcher — see *Ratatoskr* below).

## Library API

```swift
import ShenSwift

let shen = Interp()
try shen.boot()                 // load + initialise the kernel (~1 s release)
try shen.runREPL()              // or drive it yourself
```

## CLI

The refreshed kernel no longer ships the community `extension-launcher.kl`, so
shen-swift provides the launcher **natively** (`Interp.runLauncher`, driving the
kernel's own `eval` / `read-from-string` / `load`). Its command surface still
matches shen-go / shen-rust / shen-julia / ShenScript:

```sh
shen-swift                      # interactive REPL
shen-swift eval -e "(+ 1 2)"    # evaluate an expression -> 3
shen-swift script prog.shen     # run a .shen program
shen-swift --version            # 41.2 (port ("Swift" "0.1.0") ...)
```

`-q` sets `*hush*`. A host-side `pr` override makes `*hush*` gate **only
stdout** — explicit file streams still write — so shakes/loads under `-q`
behave like shen-go/shen-julia.

## Status

- Boots the refreshed **S41.2** kernel (all 15 KLambda files) in ~1 s and runs
  an interactive REPL. `(value *version*)` reports `"41.2"`.
- Passes the Swift test target (`swift test`) — **12/12**, including the
  kernel-boot test (`define`, `reverse`, tail recursion, type signatures).
- CLI verified by hand against the refreshed kernel: `--version`, `--help`,
  `eval -e/-l/-q/-r`, `script <file>`, and the bare/`repl` interactive loop.
- **Re-validation pending against the refreshed kernel** (these passed on the
  previous community 41.2 and have not yet been re-run here):
  - the external kernel test suite (`cl-source/.../tests/runme.shen`);
  - **Bifrost** cross-port conformance (`bifrost.py --impls shen-swift`);
  - **Ratatoskr** stage-1 host / stage-2 target byte-identical parity. The
    stage-2 `--shaken` path was updated to tolerate slices without a
    `shen.initialise` (the refreshed kernel has none — it initialises via
    top-level forms), but shaken slices must be **regenerated** from this kernel
    and re-checked with `bifrost --shake`.
- Phase 2 (planned): iOS SwiftUI app target; optional AOT compiler for hot
  paths; native dict/hash overrides per the Shen port performance notes.
