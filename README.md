# shen-swift

A from-scratch port of the [Shen programming language](https://shenlanguage.org)
to Swift, designed to run on macOS **and iOS**.

It is a **tree-walking KLambda interpreter**: it loads the community
**ShenOSKernel 43.1** `.kl` sources at runtime and interprets them (the release's
`klambda/` files are vendored byte-for-byte under `Sources/ShenSwift/klambda/` —
see its `PROVENANCE.md`). This is the kernel upstream shen-scheme 0.51 ships.
Because nothing is compiled or code-generated on device, it runs inside the iOS
sandbox (no JIT, no `dlopen`, no runtime `swiftc`), and supports live
`(define ...)` at the REPL.

> **Kernel note.** 43.1's `.kl` files contain only `defun`s. `boot()` loads the
> 16 runtime kernel modules (including `dict.kl`, the hash-table property store, and
> `init.kl`), installs the host overrides, then calls `(shen.initialise)`.
> Before 43.1 this port vendored Mark Tarver's *refreshed S41.2* kernel, a
> different lineage with no `shen.initialise`; see `PROVENANCE.md` for the
> history and the override audit.

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
| `Boot.swift` | Kernel load + `shen.initialise`, native overrides (`pr`, `hash`), native CLI launcher, public API |
| `klambda/` | Bundled ShenOSKernel-43.1 `.kl` sources incl. `stlib.kl` (resource) — see `klambda/PROVENANCE.md` |

### Key design points

- **Tail-call elimination.** `eval` is a `while` loop; tail positions
  (`if`/`cond`/`let`/`and`/`or`/`do` branches and saturated function
  application) rebind the current expression/environment instead of recursing.
- **Currying.** Functions carry already-supplied arguments; under-application
  returns a partial closure, over-application applies the result to the rest.
- **Native overrides.** Only `pr` (`*hush*` gates stdout only) and `hash` (a
  structural host hash consistent with `=`, which keeps the 42.x shen.dict
  property store fast). `fn`, `get`/`put`, `arity` and the lambda table are the
  kernel's own 43.1 code.
- **Deep recursion.** The CLI runs the interpreter on a 512 MB-stack thread so
  non-tail user recursion (e.g. the recursive arm of `append`) does not overflow.

## Build & run

```sh
swift build -c release
swift run -c release shen-swift            # interactive REPL
echo '(+ 1 2)' | swift run -c release shen-swift
```

Flags: `--verbose` (boot diagnostics), `--stdlib` (also load the standard
library — see *Standard library* below), `--kl <dir>` (override the kernel
directory), `--shaken <kernel.kl> <user.kl>` (Yggdrasil stage-2 mode: boot a
minimal shaken slice and run the user program to completion instead of loading
the full kernel + launcher — see *Yggdrasil* below).

## Standard library

ShenOSKernel 43.1 ships the core standard library precompiled as
`klambda/stlib.kl`. Pass `--stdlib` (CLI) or `boot(stdlib: true)` (library) to
load it and call `(stlib.initialise)`; then `filter`, `mapc`, `take`, `drop`,
`sort`, the `string`/`maths`/`tuple`/`symbol` packages, etc. are available:

```sh
shen-swift --stdlib eval -e "(filter (/. X (> X 2)) [1 2 3 4])"   # -> [3 4]
```

It stays **opt-in** so a kernel-only boot stays fast (~0.5 s release on Linux);
loading and initialising `stlib.kl` in this tree-walking interpreter adds ~6 s.
(Before 43.1 the library was compiled from Tarver's `Lib/StLib` Shen sources at
load time, ~25 s.)

## Library API

```swift
import ShenSwift

let shen = Interp()
try shen.boot()                 // load + initialise the kernel (~0.5 s release)
try shen.runREPL()              // or drive it yourself
```

## CLI

shen-swift provides the launcher **natively** (`Interp.runLauncher`, driving the
kernel's own `eval` / `read-from-string` / `load`), mirroring 42.2's
`extension-launcher.kl` (vendored, not booted). Its command surface matches
shen-go / shen-rust / shen-julia / ShenScript:

```sh
shen-swift                      # interactive REPL
shen-swift eval -e "(+ 1 2)"    # evaluate an expression -> 3
shen-swift script prog.shen     # run a .shen program
shen-swift --version            # 43.1 (port ("Swift" "0.1.0") ...)
```

`-q` sets `*hush*`. `eval -e` prints its results through `pr`, so `-q`
silences them, as in the kernel launcher. A host-side `pr` override makes
`*hush*` gate **only stdout** — explicit file streams still write — so
shakes/loads under `-q` behave like shen-go/shen-julia.

## Status

- Boots **ShenOSKernel 43.1** (16 runtime kernel modules + `shen.initialise`) and runs
  an interactive REPL. `(version)` reports `"43.1"`.
- The Swift test target covers kernel boot, public stream callables, 42.x
  compatibility checks, and `read` at EOF without a trailing newline.
- The canonical 43.1 kernel suite is hosted by the upstream Shen reference
  ports; Swift validation covers boot, public stream callables, and focused
  kernel behavior in `Tests/ShenSwiftTests`.
- **Standard library** from 43.1's precompiled `stlib.kl` under `--stdlib`.
- **Yggdrasil** `--shaken` mode calls the slice's `shen.initialise` when it has
  one; slices must be shaken from the matching 43.1 kernel.
- Phase 2 (planned): iOS SwiftUI app target; optional AOT compiler for hot
  paths; native dict overrides per the Shen port performance notes.

## Optional Nix environment

Nix is optional; the normal shen-swift build and launcher commands continue to work
with tools installed by any method. For a pinned development toolchain:

```sh
nix develop
```

The flake also exports `packages.toolchain` for composition by
[Bifrost](https://github.com/pyrex41/bifrost):

```sh
nix shell .#toolchain
```

If direnv is installed, `direnv allow` opts this checkout into the same dev
shell automatically. Nothing activates until that explicit authorization, and
Nix is never required at runtime.
