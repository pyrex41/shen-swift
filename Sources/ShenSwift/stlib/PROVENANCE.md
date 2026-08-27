# Shen 42 standard library provenance

The files in this directory are copied from Mark Tarver's Shen 42.0 archive,
`S42/Lib/StLib/`, distributed at https://www.shenlanguage.org/Download/S42.zip
(SHA-256 `30abdc7e5a1e27b7a20109c1ed141e4712885e31f24d9710d16415fbbd4dfb23`).
The mirror tag is `pyrex41/shen-upstream:s42-pristine-20260825`.

`install.shen` is run unchanged by `Interp.loadStdlib`; all source files are
kept as upstream bytes, including optional packages and precompiled fixtures.
