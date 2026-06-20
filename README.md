# shen-swift

A from-scratch port of the [Shen programming language](https://shenlanguage.org)
to Swift, designed to run on macOS **and iOS**.

It is a **tree-walking KLambda interpreter**: it loads the unmodified
ShenOSKernel-41.2 `.kl` sources at runtime and interprets them. Because nothing
is compiled or code-generated on device, it runs inside the iOS sandbox (no JIT,
no `dlopen`, no runtime `swiftc`), and supports live `(define ...)` at the REPL.

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
| `Boot.swift` | Kernel load order, environment init, native overrides, public API |
| `klambda/` | Bundled ShenOSKernel-41.2 `.kl` sources (resource) |

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

shen-swift drives the kernel's standard launcher (`shen.x.launcher.main`), so
its command surface matches shen-go / shen-rust / shen-julia / ShenScript:

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

- Boots the full unmodified 41.2 kernel and runs an interactive REPL.
- Passes the kernel test suite (`cl-source/.../tests/runme.shen`) — **35/35
  report groups, 100%**.
- **Bifrost**: registered as the 8th impl; passes all **30/30** cross-port
  conformance cases (`bifrost.py --impls shen-swift`).
- **Ratatoskr**: both a verified stage-1 **host** and a stage-2 **target**.
  As a host, shaking a program with shen-swift produces a **byte-identical
  `kernel.kl` + manifest** vs. the shen-cl reference. As a target,
  `ratatoskr run --target swift prog.shen out/` builds a slice + `run`
  launcher that drives this interpreter in `--shaken` mode: because shen-swift
  *interprets* KL (nothing to code-generate), the artifact is the shaken slice
  itself and the win is boot speed — a ~200-line shaken kernel instead of the
  full ~2500-line kernel. Load order mirrors the Scheme/Lua builders (defuns →
  native overrides → `(shen.initialise)` → top-level forms). Verified
  byte-identical with the other ports under `bifrost --shake`.
- Phase 2 (planned): iOS SwiftUI app target; optional AOT compiler for hot
  paths; native dict/hash overrides per the Shen port performance notes.
