# Standard-library provenance

These are Mark Tarver's **StLib** Shen sources, vendored so shen-swift can load
a standard library on top of the kernel (the S41.2 kernel no longer bundles
`stlib.kl` — see `../klambda/PROVENANCE.md`).

**Canonical source:** the designated mirror **`pyrex41/shen-upstream`** (formerly
`pyrex41/shen-s41.1`; old URLs redirect), tag **`s41.2-pristine-20260711`**,
directory `Lib/StLib/`. Files are vendored verbatim.

## What is vendored

Exactly the files upstream's `install.shen` loads, preserving its directory
layout, plus `install.shen` and `package-stlib.shen`:

```
install.shen  package-stlib.shen
Symbols/{symbols1,symbols2}.shen
Maths/{macros,maths,rationals,complex,numerals}.shen
Maths/{rationals,complex,numerals}.dtype
Lists/lists.shen
Strings/{macros,strings,smart}.shen
Vectors/macros.shen
IO/{prettyprint,delete-file,files}.shen
Tuples/tuples.shen
```

Not vendored (upstream StLib modules `install.shen` does not load): `Calendar/`,
`Data/`, `Maths/r.shen`, `Strings/{regex,smartmem}.shen`.

## How it is loaded

`Interp.loadStdlib()` (in `../Boot.swift`) runs upstream's `install.shen`
unmodified, with the process working directory set to this folder so its
relative `(load "…")` forms resolve. As a tree-walking interpreter, shen-swift
compiles these sources at load time (~25 s) rather than loading precompiled KL,
so the stdlib is **opt-in**: the `--stdlib` CLI flag or `boot(stdlib: true)`.
Default boots (kernel only) are unaffected (~1 s).

## Patches

**None.** `install.shen` and all vendored modules load unmodified on shen-swift.
The only port-side accommodation is in `loadStdlib` (not in these sources):
`install.shen` must be loaded with `*hush*` set, because its unhushed output
goes through shen-swift's host-side `pr` override in a way that otherwise breaks
later evaluation. Loading the stdlib hushed matches how the other ports load it.
