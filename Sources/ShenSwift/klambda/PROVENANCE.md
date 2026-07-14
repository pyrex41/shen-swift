# Kernel provenance

These KLambda (`.kl`) sources are the **refreshed S41.2 kernel** published by
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

## Caveat: same version number, different kernel

Upstream **reused the version string "41.2"** for a *restructured* kernel with a
different lineage from the community `github.com/Shen-Language/shen-sources`
kernel (tag `shen-41.2`). `(value *version*)` still reports `"41.2"`. Treat this
vendored copy as **"S41.2 (2026-07-11 refresh)"** to disambiguate.

## What changed vs. the community 41.2 kernel

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

## Per-file sha256 (as vendored)

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
