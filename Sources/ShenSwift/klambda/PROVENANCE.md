# Kernel provenance

These KLambda (`.kl`) sources are the community **ShenOSKernel 43.1** release,
the kernel shipped by upstream shen-scheme 0.51. They are vendored
**byte-for-byte** from the release tag's `klambda/` directory (all 24
files), together with the release's `LICENSE.txt`.

- **Repository:** <https://github.com/Shen-Language/shen-sources>
- **Tag:** `shen-43.1`
- **Commit:** `715824a52b55e9c81a9501df8548ff3edd8411f5`
- **Release asset:** `ShenOSKernel-43.1.tar.gz`
- **Asset SHA-256:** `900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`
- **Extracted from:** `ShenOSKernel-43.1/klambda/`
- `(version)` → `"43.1"` (set by `shen.initialise-environment` in `init.kl`)

## Lineage choice

**Adopt ShenOSKernel-43.1 wholesale.** This replaces the
refreshed S41.2 kernel (Mark Tarver's lineage, mirror `pyrex41/shen-s41.1` tag
`s41.2-pristine-20260711`, kept below as history). This port never vendored
Tarver's S42.0, so the upgrade also brings in the 42.0 changes (lambda-form
invalidation on arity change, S42 kernel error strings such as the trailing
newline in the `(head [])` message).

Structural consequences for the boot (see `Boot.swift`):

- Every `.kl` file holds only `defun`s; there are no top-level forms to order.
  `boot()` loads the 17 kernel modules (`sys writer core reader declarations
  toplevel macros load prolog sequent track t-star yacc types dict compiler init`),
  installs the host overrides, then calls `(shen.initialise)`.
- `dict.kl` is back: `*property-vector*` is a `shen.dict` (hash buckets), which
  also holds the arity table and lambda forms.
- `stlib.kl` is the precompiled standard library. `--stdlib` / `boot(stdlib:)`
  loads it and calls `(stlib.initialise)` (doc/port-upgrades.md, 41.1). It
  replaces the Tarver `Lib/StLib` Shen sources this port previously compiled at
  load time (`Sources/ShenSwift/stlib/`, removed).
- The `extension-*.kl` files are vendored but **not booted**. The CLI
  launcher stays native (`Interp.runLauncher`), mirroring
  `extension-launcher.kl`'s command surface.
- The S41.2 `backend.kl` (`cl.*` Common-Lisp backend) is gone.

## Host override audit (43.1)

| Override | Status |
|----------|--------|
| `fn` | **Removed.** The S41.2-era native read the symbol's function slot; the kernel's 42.2 `fn` reads lambda forms from the shen.dict and honours the 42.0 arity-0 invalidation. |
| `get` / `put` / `unput` / `arity` / lambda-table | Not overridden; kernel code against its own shen.dict. No `shen.*lambdatable*` shim. |
| `hash` | **New native** (doc/port-performance.md "Hashing"): deterministic FNV-1a structural hash consistent with `=` (1 / 1.0, `true` / `(intern "true")`, equal lists/vectors); 0 maps to 1 as in the kernel; non-positive or non-integer bounds defer to the kernel definition. Installed before `shen.initialise` builds the dict. |
| `pr` | Kept: `*hush*` gates stdout only; explicit file streams still write (Yggdrasil shakes run under `-q`). |
| reader / `macroexpand` / `shen.macroexpand-h` / `shen.try-parse` | Not overridden, so the 42.1 source-form handler order and 4-argument `shen.macroexpand-h` are the kernel's. |
| stdin `read-byte` | Returns -1 once at EOF when a partial line is pending, so a final line without a trailing newline is read (42.1); EOF at a line boundary still exits the REPL. File streams return -1 at EOF. |
| `char-stream?` | `false` for byte-oriented Swift streams. |
| `read-unit-string` / `write-string` | Public 43.1 callables are defined for metadata. `read-unit-string` reports a catchable unsupported-operation error before consuming byte streams; `write-string` writes UTF-8 bytes and returns its string. |

## Historical 42.2 per-file sha256

The following manifest is retained as historical evidence from the previous
42.2 baseline; the current files above are pinned to the 43.1 release asset.

```
9c0ef84f269a23cbdde12918f12e3619d8a186893cfc029f5e30cc7807e200e1  core.kl
b35c94d4648edf4d1076bf848cf6ddba288938229e41c03f770cfc4108aae35d  declarations.kl
91ec5680027bb3b62fb98eda01d510d9d3980f6890b32f1198a50e6143c3e371  dict.kl
caa04fc798f230c2a76a696aad08e8ba2db7a686a0c6e2ede1681bf3f547fa4a  extension-expand-dynamic.kl
75dde0f6d36e254e4204cbf4fcee94c7daafdd3993c686a8a60a1a134b578c48  extension-features.kl
b7d3016460aae3d505ea01a548fa56a0994fa405edf423d656a5f61ed1375ef0  extension-launcher.kl
21068ec77f28ca0adf6f03062b3e4d4e05a8e52e6311624fc43f2e1a3c61b75c  extension-namespaces.kl
492d381093456c530b86f81f8332df0dddc4f36f6c7940103c486949b1b0b1fe  extension-programmable-pattern-matching.kl
2f16da65b7c6a4936ea1d07ee9bfb01bfd100ff8eff8dc5f15bf0a32c8e056db  extension-type-annotations.kl
3dbc7796b3408888d0b2a39b324676c3d1687e65fccc90068d2165d188c03491  init.kl
cd4cea54af5bd5d4ce03582d270e1e6bd3a6951e51e38ffacf28d16d508a7675  load.kl
190a6ef7072745019517139985a7e185fded43ac8d612ec49a6f9b02a9efd02b  macros.kl
2949cde531e778cb876b15c653fc9388313d53f5771df995ffc4abd81773e56f  prolog.kl
1fb0831d4c656ed2cb7c90bd6d3aa69a6f5cb637c8afdc7bf50fa9130f5f628f  reader.kl
32f5ba6d97d774465bb0efcf6f04f8b667b8ce99cde40e0b471a03bec8ecdd6a  sequent.kl
6184228e4420918c2fd6f45f90a8b08e44ea815cf86b337b2b2653984e44c86b  stlib.kl
df41e05c4a64af6ad1223c55a01c03f81b4e031aa6cccb671928aa03591040b9  sys.kl
c3c90732a49586c1280bafa5bac52ff037d5e81ff853baecf9f7cccd76145295  t-star.kl
702ca0eb844198c752f696b17cdae3653015de2980dbbb5dd69f55d13d650ea4  toplevel.kl
67ff9e8de5019e42ecfa8df2cef1961bc28487c2f4678f842eadf4f4314c9825  track.kl
9e83288d9b1647c9a0d3a0d6796a26b828968c6509d1179923f2c47101d879df  types.kl
5e6f6374fc1fd7ec4b3f9eab79467b8c93393d721cecef2f22ccf84fdef39070  writer.kl
bd178ad4cf028115fabd1e7f3b00f202f73be1380b71a6111de3a0ce0bf30ad8  yacc.kl
aec4473b0b8990ce8ab3344f75cdc0ec11da50020405a44b4b50453789dbf948  LICENSE.txt
```

# History: refreshed S41.2 kernel (vendored until this upgrade)

The record below is kept verbatim from before the 42.2 upgrade. At that time
the standard library was vendored separately as Tarver's `Lib/StLib` Shen
sources (`Sources/ShenSwift/stlib/`, mirror `pyrex41/shen-upstream` tag
`s41.2-pristine-20260711`), now removed in favour of 42.2's `stlib.kl`.

The KLambda (`.kl`) sources were then the **refreshed S41.2 kernel** published by
Mark Tarver, not the community `ShenOSKernel-41.2` this port previously vendored.

**Canonical source:** `pyrex41/shen-s41.1`, the designated mirror of Tarver's
uploads — tag **`s41.2-pristine-20260711`**, commit **`11fc51b`**, directory
`KLambda/` (15 files). The files vendored here are **byte-identical** to that
tag (verified by sha256; see the table below).

Upstream origin, mirrored by that tag (secondary detail):

- **URL:** <https://www.shenlanguage.org/Download/S41.2.zip>
- **Last-Modified:** 2026-07-11 (re-upload)
- **Archive sha256:** `51becbfd60fa8c93c3f8ae5b20b948eaa84c4b1d14ad2f5d2a056002a53ee836`
- **Extracted from:** `S41/KLambda/` inside that archive

### Caveat: same version number, different kernel

Upstream **reused the version string "41.2"** for a *restructured* kernel with a
different lineage from the community `github.com/Shen-Language/shen-sources`
kernel (tag `shen-41.2`). `(value *version*)` still reports `"41.2"`. Treat this
vendored copy as **"S41.2 (2026-07-11 refresh)"** to disambiguate.

### What changed vs. the community 41.2 kernel

Removed here (were vendored before): `compiler.kl`, `dict.kl` (the dict layer is
gone; pointer ops `shen.change-pointer-value` / `shen.remove-pointer` replace
it), `init.kl` (its `shen.initialise` is gone — initialisation now happens via
top-level forms in `declarations.kl` and `types.kl`), `stlib.kl` (the standard
library now ships as lazy Shen sources under upstream `Lib/StLib`, **not vendored
here**), and the community `extension-*.kl` files (features / expand-dynamic /
programmable-pattern-matching / **launcher**). The launcher CLI is now provided
natively by `Interp.runLauncher` (see `Boot.swift`).

New here: `backend.kl` — a `cl.*` KLambda→Common Lisp backend. It is **inert for
this Swift port** (it contains only `defun`s that reference uppercase CL
primitives like `MEMBER`/`GENSYM`/`CL.MAPCAR`, which this interpreter never
calls); it is vendored because it is part of upstream's boot list.

### Per-file sha256 (as vendored)

```
e9e7dc25553e995b340b5579b08f6f08511ddf585f3e6eef8efc9cff5e696c77  backend.kl
7a0e84f3d3440b304fb9e941083084f3aeee3dadd39e5d1583a9f794606e18c0  core.kl
f3bf157fdae284398c349279d8c3520dd3c24e0f8f3cd536ca4b006db3cce505  declarations.kl
645bec2ed38e814e2b95964a6c2f5bb33651715667628b1aea0fb74a06977039  load.kl
b56908645678cc4b13f86aa181abf821e7bc571bbb8a855665b8d74bc446f7f9  macros.kl
021010d04df3a185929d99710446faf2aa9bfc92f22d415b5d1d7b094c69214c  prolog.kl
ac31f27d456ef6f97aa04fcec4d021566f6c9d7f1753477f5cd8c82fb515aad4  reader.kl
c3ad3da602d71359df5417bd83beeb7ea22dbcd5b66dbf1e7c0bc7ff2d8cac27  sequent.kl
2222308f599ced021dca4d7d673e7441c2dcbb598f17775c459d09d72d5228bb  sys.kl
6d8d36133772d62f6db42bcdd57e38ce278eac134e6f9969592881aaf6cb392d  t-star.kl
c9dd97fd48ee5f526f6ba9469c57ec30a5f35ca99f7d0dbeefe639ebe2f1a3d8  toplevel.kl
87144cd135d94c151d88df31d9baf50b97cfd0fd1c41475d01bc801eaf8f37c1  track.kl
12a86f957e20ca063abd0a85264198feb970b897ab3fc1280f3a7a65108f8408  types.kl
a09078bb034fc91fdd04d9180ca02b00abfb7fe0c95d5d743cbc66c17cc87445  writer.kl
192880765a29ae6801ef9088a7511e4477be998e6c16ab82f3cc3a2087727f00  yacc.kl
```
