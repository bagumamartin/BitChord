# QuackJS

Source: https://github.com/MetrolistGroup/quackjs
Pinned revision: d867d98f9f2562009399cdfecd67e626a086f878 (0.1.4)

The JavaScript interpreter `vendor/innertubex` runs YouTube player scripts in.
It is vendored because upstream publishes no macOS arm64 artifact.

`src/commonMain` is upstream's, unmodified; its tests and player fixtures are
not copied. `LICENSE` (GPL-3.0-only), `README.md`, `THIRD_PARTY_NOTICES.md` and
`licenses/` are upstream's. The local `build.gradle.kts` declares only the
Apple targets BitChord builds.
