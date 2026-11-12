# InnerTubeX Apple integration

Source: https://github.com/MetrolistGroup/innertubex
Pinned revision: 64c7df4d88d27e6964157b3b341f7ec70f88ea6e (v0.11.6)

`src/` is upstream's tree at that revision, unmodified: `commonMain`,
`nativeMain`, `commonTest` and `nativeTest`. Upstream's Android, JVM and
Windows source sets are not copied. `LICENSE`, `README.md`, `SECURITY.md` and
`CHANGELOG.md` are upstream's.

The local `build.gradle.kts` is the only adapter. It adds macOS arm64 alongside
upstream's iOS targets, leaves out the Android/JVM targets and publishing
plugins, and takes QuackJS from `vendor/quackjs` because upstream publishes no
macOS arm64 artifact of it.

Player-script work (signature and `n` transforms) runs in QuackJS, a
pure-Kotlin interpreter, on upstream's own large-stack native threads
(`CipherDispatcher.native.kt`). The JavaScriptCore adapter this directory
carried for the earlier EJS solver is gone with that solver.

BitChord supplies upstream's visitor-bound player-request token and video-bound
streaming-data token through an isolated WKWebView. Challenge HTTP uses a public,
cookie-free client; web rendering blocks network loads, matching upstream.

To update: replace `src/` and the four upstream documents from the new tag,
move the pin above, match Ktor and kotlinx versions to upstream's
`gradle/libs.versions.toml` here and in `shared/build.gradle.kts`, check
whether the QuackJS pin moved, then run `:innertubex:macosArm64Test` and
`:shared:macosArm64Test`.
